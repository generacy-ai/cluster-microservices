#!/bin/bash
# Entrypoint for the Generacy orchestrator container
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [orchestrator] $*"
}

log "Starting orchestrator setup..."

# Start Docker-in-Docker daemon and configure host context
bash /usr/local/bin/setup-docker-dind.sh

# Source wizard-delivered credentials persisted by a prior bootstrap
# (written by control-plane's bootstrap-complete handler — see
# generacy-ai/generacy#589). On restarts of an already-bootstrapped
# cluster, GH_TOKEN lives only in this file; without it, setup-credentials
# warns and the later `git fetch` in resolve-workspace.sh fails auth.
# Mirrors the same sourcing block in entrypoint-post-activation.sh.
WIZARD_CREDS="${WIZARD_CREDS_PATH:-/var/lib/generacy/wizard-credentials.env}"
if [ -f "$WIZARD_CREDS" ]; then
    log "Sourcing wizard credentials from $WIZARD_CREDS"
    set -a
    # shellcheck disable=SC1090
    source "$WIZARD_CREDS"
    set +a
fi

# Configure git credentials
bash /usr/local/bin/setup-credentials.sh

# Resolve workspace directory (handles devcontainer detection + clone)
source /usr/local/bin/resolve-workspace.sh

# Load cluster.yaml defaults (sets GENERACY_CHANNEL, WORKER_COUNT, WORKERS_ENABLED
# if not already provided via .env or environment)
source /usr/local/bin/load-cluster-config.sh

# Install generacy/agency packages into shared volume
SHARED_PACKAGES=/shared-packages
CHANNEL="${GENERACY_CHANNEL:-stable}"
MARKER_FILE="${SHARED_PACKAGES}/.installed-version"

install_packages() {
    log "Installing @generacy-ai packages (channel: ${CHANNEL}) into ${SHARED_PACKAGES}..."
    npm install \
        --prefix "${SHARED_PACKAGES}" \
        --no-save \
        "@generacy-ai/generacy@${CHANNEL}" \
        "@generacy-ai/agency@${CHANNEL}" \
        "@generacy-ai/agency-plugin-spec-kit@${CHANNEL}" \
        "@generacy-ai/cluster-relay@${CHANNEL}" \
        "@generacy-ai/control-plane@${CHANNEL}" \
        2>>"$SETUP_LOG" || { log "ERROR: npm install failed"; exit 1; }
    # Write marker: channel + installed version of generacy
    local version
    version=$(node -e "console.log(require('${SHARED_PACKAGES}/node_modules/@generacy-ai/generacy/package.json').version)" 2>/dev/null || echo "unknown")
    echo "${CHANNEL}:${version}" > "${MARKER_FILE}"
    log "Packages installed (version: ${version})"
}

SETUP_LOG="${SETUP_LOG:-/tmp/generacy-setup.log}"
if [ "${SKIP_PACKAGE_UPDATE:-false}" = "true" ]; then
    log "SKIP_PACKAGE_UPDATE=true — skipping npm install"
else
    install_packages
fi

# Add shared packages to PATH for this process
export PATH="${SHARED_PACKAGES}/node_modules/.bin:${PATH}"

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

# Light check: warn if speckit is missing (orchestrator can still run).
# Skip in wizard mode — speckit lives in the not-yet-cloned workspace.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" != "wizard" ] && [ -x "/usr/local/bin/setup-speckit.sh" ]; then
    if ! bash /usr/local/bin/setup-speckit.sh --verify 2>/dev/null; then
        log "WARNING: Speckit commands not available. Workers may fail to process phases."
    fi
fi

# Wizard mode: arm the post-activation hook.
# Spawns a background watcher that fires entrypoint-post-activation.sh when
# the bootstrap-complete sentinel appears. The trigger contract is documented
# in post-activation-watcher.sh — control-plane (generacy-cloud#532) creates
# the sentinel after persisting wizard-delivered credentials.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" = "wizard" ]; then
    POST_ACTIVATION_TRIGGER="${POST_ACTIVATION_TRIGGER:-/tmp/generacy-bootstrap-complete}"
    log "Arming post-activation watcher (trigger: ${POST_ACTIVATION_TRIGGER})"
    POST_ACTIVATION_TRIGGER="${POST_ACTIVATION_TRIGGER}" \
        bash /usr/local/bin/post-activation-watcher.sh &
fi

# Wait for Redis to be ready
log "Waiting for Redis at ${REDIS_HOST:-redis}:6379..."
while ! nc -z "${REDIS_HOST:-redis}" 6379 2>/dev/null; do
    sleep 1
done
log "Redis is ready"

# Start the in-cluster control-plane daemon. It owns the unix socket the
# orchestrator's StatusReporter writes to AND serves the /control-plane/*
# routes that the cloud relay forwards (e.g. PUT /control-plane/credentials/:id
# during the bootstrap wizard's "Install GitHub App" step).

# Shared internal-API key so the control-plane process can POST events back
# to the orchestrator's /internal/relay-events endpoint, which then forwards
# them through the cluster-relay client. See generacy-ai/generacy#594.
# Generated per-boot — never persisted, never leaves the container.
export ORCHESTRATOR_INTERNAL_API_KEY="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

CONTROL_PLANE_SOCKET_PATH="${CONTROL_PLANE_SOCKET_PATH:-/run/generacy-control-plane/control.sock}"
export CONTROL_PLANE_SOCKET_PATH
CONTROL_PLANE_LOG="${CONTROL_PLANE_LOG:-/tmp/control-plane.log}"

if [ -x "${SHARED_PACKAGES}/node_modules/.bin/control-plane" ]; then
    log "Starting control-plane daemon (socket: ${CONTROL_PLANE_SOCKET_PATH}, log: ${CONTROL_PLANE_LOG})"
    "${SHARED_PACKAGES}/node_modules/.bin/control-plane" >>"${CONTROL_PLANE_LOG}" 2>&1 &

    # Wait for the socket so the orchestrator's first StatusReporter push lands
    # cleanly. Bounded so a wedged daemon doesn't block startup forever — if
    # the socket never appears we log and continue; StatusReporter will retry.
    for _ in $(seq 1 50); do
        [ -S "${CONTROL_PLANE_SOCKET_PATH}" ] && break
        sleep 0.2
    done
    if [ -S "${CONTROL_PLANE_SOCKET_PATH}" ]; then
        log "Control-plane socket ready"
    else
        log "WARNING: control-plane socket not ready after 10s (see ${CONTROL_PLANE_LOG})"
    fi
else
    log "WARNING: control-plane binary not found in ${SHARED_PACKAGES}/node_modules/.bin/ — relay-forwarded /control-plane/* requests will 404"
fi

# Start orchestrator as PID 1
log "Starting orchestrator on port ${ORCHESTRATOR_PORT:-3100}..."
exec generacy orchestrator \
    --port "${ORCHESTRATOR_PORT:-3100}" \
    --redis-url "${REDIS_URL:-redis://redis:6379}" \
    ${LABEL_MONITOR_ENABLED:+--label-monitor}
