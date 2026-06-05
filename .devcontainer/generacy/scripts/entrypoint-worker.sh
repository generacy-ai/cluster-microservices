#!/bin/bash
# Entrypoint for Generacy worker containers
set -e

export AGENT_ID="${AGENT_ID:-$HOSTNAME}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [worker:${AGENT_ID}] $*"
}

# Credentials architecture (v1.5): block cross-process ptrace before any
# secret-handling subprocess starts. Yama is a host-global LSM parameter so
# this is a no-op when the host already has it set (recommended for shared
# hosts). Soft-fails on unprivileged containers — the entrypoint warns but
# continues so non-credentialed workflows still run.
echo 1 > /proc/sys/kernel/yama/ptrace_scope 2>/dev/null \
    || echo "[warn] Could not set ptrace_scope=1 (requires privileged mode or host-level sysctl)"

# Credentials state dir: 0700 owned by node (uid 1000). Pre-created in the
# image so the named volume inherits perms on first-init; this block is the
# idempotent runtime guard for re-runs and pre-existing volumes.
if [ -d /var/lib/generacy ]; then
    chmod 0700 /var/lib/generacy 2>/dev/null || true
fi

log "Starting worker setup..."

# Start Docker-in-Docker daemon (workers get DinD but not host context)
bash /usr/local/bin/setup-docker-dind.sh

# Source wizard-delivered credentials persisted by a prior bootstrap (written
# by control-plane's bootstrap-complete handler — see generacy-ai/generacy#589).
# On an already-bootstrapped cluster GH_TOKEN lives only in this file; without
# it, setup-credentials.sh warns and the clone in resolve-workspace.sh (and the
# per-job clone in the worker) fails auth with "could not read Username for
# 'https://github.com'". Mirrors the identical block in entrypoint-orchestrator.sh
# and entrypoint-post-activation.sh so the worker has the same credentials as the
# orchestrator (generacy-ai/generacy#632).
WIZARD_CREDS="${WIZARD_CREDS_PATH:-/var/lib/generacy/wizard-credentials.env}"
if [ -f "$WIZARD_CREDS" ]; then
    log "Sourcing wizard credentials from $WIZARD_CREDS"
    set -a
    # shellcheck disable=SC1090
    source "$WIZARD_CREDS"
    set +a
fi

# Source app-config env vars set via the bootstrap wizard / Settings panel so
# worker + child processes (agent workflows, MCP servers, user services)
# inherit user-configured values like LIVEKIT_URL, SERVICE_ANTHROPIC_API_KEY.
#   - /var/lib/generacy-app-config/env       non-secret, RO mount from named
#     volume the orchestrator's control-plane writes
#   - /run/generacy-app-config/secrets.env   secret, per-worker tmpfs. Empty
#     in v1 — propagation from the orchestrator is TBD (see issue #38 Open
#     question / generacy-ai/generacy#632); guarded by -f so the no-file case
#     is a silent no-op.
for app_env in /var/lib/generacy-app-config/env /run/generacy-app-config/secrets.env; do
    if [ -f "$app_env" ]; then
        log "Sourcing app-config env from $app_env"
        set -a
        # shellcheck disable=SC1090
        source "$app_env"
        set +a
    fi
done

# Configure git credentials.
#
# Workers have no local control-plane daemon, so the JIT git credential helper
# (generacy-ai/cluster-base#61) cannot reach the control socket directly. Point
# it at the orchestrator-hosted git-token proxy, whose socket lives on a volume
# shared with this container. setup-credentials.sh bakes this path into git
# config so later git ops (including agent workflows under a different uid)
# route through it. The proxy ships in @generacy-ai/control-plane
# (generacy-ai/generacy#768); the orchestrator launches it — see
# entrypoint-orchestrator.sh.
export GIT_TOKEN_SOCKET_PATH="${GIT_TOKEN_PROXY_SOCKET:-/run/generacy-git-token/control.sock}"
bash /usr/local/bin/setup-credentials.sh

# Resolve workspace directory (handles devcontainer detection + clone)
source /usr/local/bin/resolve-workspace.sh

# Load cluster.yaml defaults (sets GENERACY_CHANNEL, WORKER_COUNT, WORKERS_ENABLED
# if not already provided via .env or environment)
source /usr/local/bin/load-cluster-config.sh

# Set up CLI wrappers pointing to shared packages volume
SHARED_PACKAGES=/shared-packages
LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "${LOCAL_BIN}"

for cli in generacy agency; do
    WRAPPER="${LOCAL_BIN}/${cli}"
    cat > "${WRAPPER}" <<EOF
#!/bin/sh
exec node ${SHARED_PACKAGES}/node_modules/.bin/${cli} "\$@"
EOF
    chmod +x "${WRAPPER}"
done

# Ensure ~/.local/bin is on PATH for this process and subprocesses
export PATH="${LOCAL_BIN}:${PATH}"
if ! grep -q 'local/bin' "${HOME}/.bashrc" 2>/dev/null; then
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.bashrc"
fi

log "CLI wrappers created in ${LOCAL_BIN}"

# Run generacy setup if CLI is available.
# In wizard mode the workspace isn't cloned yet (credentials arrive post-activation),
# so workspace/build steps are deferred to entrypoint-post-activation.sh.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" = "wizard" ]; then
    log "Wizard mode — skipping pre-activation generacy setup; will run after activation"
elif command -v generacy >/dev/null 2>&1; then
    SETUP_LOG="/tmp/generacy-setup.log"
    log "Running generacy setup..."

    # Non-critical: log errors but continue
    generacy setup auth 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup auth' failed (see $SETUP_LOG)"

    # Important: log errors but continue (workspace needed for build)
    # Pass --config when config file exists to avoid ambiguity with multiple repos
    CONFIG_PATH="${WORKSPACE_DIR}/.generacy/config.yaml"
    if [ -f "$CONFIG_PATH" ]; then
        generacy setup workspace --config "$CONFIG_PATH" --clean 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup workspace' failed (see $SETUP_LOG)"
    else
        generacy setup workspace --clean 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup workspace' failed (see $SETUP_LOG)"
    fi

    # Critical: trigger speckit recovery on failure
    generacy setup build 2>>"$SETUP_LOG" || {
        log "ERROR: 'generacy setup build' failed — attempting speckit recovery (see $SETUP_LOG)"
        bash /usr/local/bin/setup-speckit.sh 2>>"$SETUP_LOG" || log "ERROR: speckit recovery also failed (see $SETUP_LOG)"
    }
fi

# Pre-flight: verify speckit readiness.
# Skip in wizard mode — speckit lives in the not-yet-cloned workspace. The worker
# idles in this state until post-activation completes setup and restarts the
# worker containers (entrypoint-post-activation.sh step 5,
# generacy-ai/cluster-base#59); that restart re-runs this entrypoint with creds +
# repo present, so the verify below then runs against a populated workspace.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" != "wizard" ] && [ -x "/usr/local/bin/setup-speckit.sh" ]; then
    if ! bash /usr/local/bin/setup-speckit.sh --verify; then
        log "FATAL: Speckit commands not available. Worker cannot process phases."
        log "FATAL: Check ${SETUP_LOG:-/tmp/generacy-setup.log} for setup errors."
        log "FATAL: Ensure agency repo is accessible and 'generacy setup build' succeeds."
        exit 1
    fi
fi

# Start worker as PID 1
log "Starting worker ${AGENT_ID}..."
exec generacy orchestrator \
    --port "${HEALTH_PORT:-9001}" \
    --redis-url "redis://${REDIS_HOST:-redis}:${REDIS_PORT:-6379}" \
    --worker-only
