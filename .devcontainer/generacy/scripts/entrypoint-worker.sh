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

# Give this container its own ~/.claude.json before anything writes to it.
# Must run before `generacy setup auth` / `setup build`, which populate
# mcpServers — see seed-claude-config.sh for why the file is no longer shared.
bash /usr/local/bin/seed-claude-config.sh || true

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

# Has this container's cluster finished bootstrapping?
#
# GENERACY_BOOTSTRAP_MODE is a static compose value: it stays "wizard" for the
# whole life of the container, including across the post-activation worker
# restart. Gating setup on the mode alone therefore skipped it FOREVER on
# wizard (UI-launched) clusters — the restart re-runs this entrypoint with the
# same value and takes the same "defer" branch, so `generacy setup build` never
# ran and mcpServers.agency was never written. Workers then launched Claude with
# no Agency MCP server and every phase silently fell back to raw bash.
#
# That went unnoticed while all containers shared one ~/.claude.json: the
# orchestrator's post-activation `setup build` wrote the entry and workers
# inherited it. Once each container got its own config, the inheritance stopped
# and this latent gap became visible.
#
# The wizard credentials file is the real activation signal — it is written by
# control-plane's bootstrap-complete handler and is precisely what the
# post-activation restart makes available. Sourced above.
SETUP_READY=true
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" = "wizard" ] && [ ! -f "$WIZARD_CREDS" ]; then
    SETUP_READY=false
fi

# Run generacy setup if CLI is available.
# Before activation the credentials (and workspace) are not there yet, so
# workspace/build steps wait for the post-activation restart.
if [ "$SETUP_READY" != "true" ]; then
    log "Wizard mode, not yet activated — deferring generacy setup until after activation"
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

    # Re-assert git credential wiring after the generacy setup steps.
    #
    # `generacy setup auth` / `setup workspace` predate the JIT credential
    # helper: given the wizard GH_TOKEN (the 1-hour activation token sourced
    # above) they configure `credential.helper store` + ~/.git-credentials and
    # run `gh auth setup-git`, both of which replace the JIT helper that
    # setup-credentials.sh wired at the top of this entrypoint. Workers then
    # sit on a static token that dies an hour after it was minted — every
    # clone 401s and restarts fail immediately once wizard-credentials.env is
    # older than an hour. generacy-ai/generacy#1105 makes the setup commands
    # JIT-aware; this re-run keeps workers safe on generacy versions that
    # predate it. Idempotent both ways: wizard mode tears down static wiring
    # and re-installs the JIT helper, local-dev mode re-seeds the static
    # token unchanged.
    bash /usr/local/bin/setup-credentials.sh
fi

# Keep the JIT helper authoritative for the life of the container (wizard
# mode only — the guard self-exits otherwise). The guard was originally
# orchestrator-only on the assumption that VS Code, which attaches to the
# orchestrator, is the only thing that clobbers git credential config; the
# generacy setup steps above proved workers need it too, and it also covers
# any in-workflow tooling that rewrites ~/.gitconfig mid-job.
bash /usr/local/bin/git-helper-guard.sh &

# Pre-flight: verify speckit readiness.
# Skipped before activation — speckit lives in the not-yet-cloned workspace. The
# worker idles in this state until post-activation completes setup and restarts
# the worker containers (entrypoint-post-activation.sh step 5,
# generacy-ai/cluster-base#59); that restart re-runs this entrypoint with creds
# present, so SETUP_READY flips to true and the verify below runs for real.
#
# It previously keyed off GENERACY_BOOTSTRAP_MODE, which never changes, so this
# check was permanently dead on wizard clusters — which is why workers ran four
# issues' worth of phases with zero agency tools and nothing said a word.
if [ "$SETUP_READY" = "true" ] && [ -x "/usr/local/bin/setup-speckit.sh" ]; then
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
