#!/bin/bash
# Post-activation entrypoint — runs once after the bootstrap wizard hands
# credentials to the cluster (GENERACY_BOOTSTRAP_MODE=wizard flow).
#
# Trigger:
#   entrypoint-orchestrator.sh spawns post-activation-watcher.sh in wizard
#   mode. The watcher polls a sentinel file (default
#   /tmp/generacy-bootstrap-complete) and runs this script when the file
#   appears. Control-plane creates the sentinel as part of its
#   bootstrap-complete lifecycle handler (generacy-cloud#532).
#
#   For local testing, create the sentinel manually:
#     docker compose exec orchestrator touch /tmp/generacy-bootstrap-complete
#
#   Or invoke this script directly (bypassing the watcher):
#     docker compose exec orchestrator /usr/local/bin/entrypoint-post-activation.sh
#
# Steps:
#   1. Re-run setup-credentials.sh now that GH_TOKEN / friends are populated.
#   2. Re-run resolve-workspace.sh to perform the deferred clone.
#   3. Run `generacy setup workspace` + `generacy setup build` against the
#      now-populated workspace so workers can pick up speckit.
#
# Idempotent — safe to invoke multiple times.

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-activation] $*"
}

log "Starting post-activation setup..."

# Source wizard-delivered credentials (written by control-plane's
# bootstrap-complete handler — see generacy-ai/generacy#589).
# set -a auto-exports each assigned variable so child processes inherit them.
WIZARD_CREDS="${WIZARD_CREDS_PATH:-/var/lib/generacy/wizard-credentials.env}"
if [ -f "$WIZARD_CREDS" ]; then
    log "Sourcing wizard credentials from $WIZARD_CREDS"
    set -a
    # shellcheck disable=SC1090
    source "$WIZARD_CREDS"
    set +a
fi

# Step 1: configure git/gh credentials from the env vars the wizard delivered
bash /usr/local/bin/setup-credentials.sh

# Step 2: clone (or pull) the project repo. resolve-workspace.sh exports
# WORKSPACE_DIR and the wizard-mode branch is a no-op once GENERACY_BOOTSTRAP_MODE
# is removed/changed; for now force the clone branch by unsetting it locally.
GENERACY_BOOTSTRAP_MODE="" source /usr/local/bin/resolve-workspace.sh

# Step 3: run the workspace-dependent generacy setup. Mirrors the block in
# entrypoint-orchestrator.sh that gets skipped during wizard-mode boot.
SHARED_PACKAGES=/shared-packages
export PATH="${SHARED_PACKAGES}/node_modules/.bin:${PATH}"

if command -v generacy >/dev/null 2>&1; then
    SETUP_LOG="/tmp/generacy-setup.log"
    log "Running generacy setup..."

    generacy setup auth 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup auth' failed (see $SETUP_LOG)"

    CONFIG_PATH="${WORKSPACE_DIR}/.generacy/config.yaml"
    if [ -f "$CONFIG_PATH" ]; then
        generacy setup workspace --config "$CONFIG_PATH" --clean 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup workspace' failed (see $SETUP_LOG)"
    else
        generacy setup workspace --clean 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup workspace' failed (see $SETUP_LOG)"
    fi

    generacy setup build 2>>"$SETUP_LOG" || {
        log "ERROR: 'generacy setup build' failed — attempting speckit recovery (see $SETUP_LOG)"
        bash /usr/local/bin/setup-speckit.sh 2>>"$SETUP_LOG" || log "ERROR: speckit recovery also failed (see $SETUP_LOG)"
    }
else
    log "WARNING: generacy CLI not on PATH — skipping setup. Restart the orchestrator container to install."
fi

log "Post-activation setup complete"
