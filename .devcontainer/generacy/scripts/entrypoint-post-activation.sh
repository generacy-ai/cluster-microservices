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
#   4. Mark post-activation complete (completion flag) ONLY when the workspace
#      was actually produced.
#
# Idempotent — safe to invoke multiple times.
#
# Failure contract (generacy-ai/cluster-base#54): when REPO_URL names a primary
# repo that still needs cloning, GH_TOKEN MUST be present. A token-less clone of
# a private repo no-ops, and because the watcher is one-shot a silent success
# would leave the cluster with no workspace and never retry. So we refuse to
# proceed without the token and exit non-zero. The orchestrator's
# PostActivationRetryService keys its retry off the completion flag
# (needsRetry = activated && !postActivationComplete), so NOT writing the flag
# on failure is what makes the clone get retried once credentials land.

set -e

# Completion flag the orchestrator's PostActivationRetryService watches. Written
# only on confirmed success (workspace present) — see end of script.
COMPLETION_FLAG="${POST_ACTIVATION_COMPLETE_FLAG:-/var/lib/generacy/post-activation-complete}"

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

# Source app-config env vars so the post-activation generacy setup sees
# user-configured values. Mirrors the same block in entrypoint-orchestrator.sh.
for app_env in /var/lib/generacy-app-config/env /run/generacy-app-config/secrets.env; do
    if [ -f "$app_env" ]; then
        log "Sourcing app-config env from $app_env"
        set -a
        # shellcheck disable=SC1090
        source "$app_env"
        set +a
    fi
done

# Determine whether a primary-repo clone still has to happen. Mirrors the path
# derivation in resolve-workspace.sh so we can check before doing any work.
CLONE_REQUIRED=false
if [ -n "${REPO_URL:-}" ]; then
    REPO_NAME=$(basename "${REPO_URL%.git}")
    EXPECTED_WORKSPACE="${WORKSPACE_DIR:-/workspaces/${REPO_NAME}}"
    if [ ! -d "${EXPECTED_WORKSPACE}/.git" ]; then
        CLONE_REQUIRED=true
    fi
fi

# Guard: a token-less clone of a private repo silently no-ops. If a clone is
# required but GH_TOKEN is absent, refuse to proceed and exit non-zero so the
# completion flag is never written and the retry service re-runs us once the
# credentials arrive (see Failure contract above; generacy-ai/cluster-base#54).
if [ "$CLONE_REQUIRED" = true ] && [ -z "${GH_TOKEN:-}" ]; then
    log "ERROR: primary repo clone required (REPO_URL=${REPO_URL}) but GH_TOKEN is missing/empty."
    log "Refusing a token-less clone — exiting non-zero so post-activation is retried once credentials land."
    exit 1
fi

# Step 1: configure git/gh credentials from the env vars the wizard delivered
bash /usr/local/bin/setup-credentials.sh

# Step 2: clone (or pull) the project repo. resolve-workspace.sh exports
# WORKSPACE_DIR and the wizard-mode branch is a no-op once GENERACY_BOOTSTRAP_MODE
# is removed/changed; for now force the clone branch by unsetting it locally.
GENERACY_BOOTSTRAP_MODE="" source /usr/local/bin/resolve-workspace.sh

# Verify the clone actually produced the workspace. resolve-workspace.sh's
# "pull" branch swallows fetch/pull errors, so a no-op can otherwise look like
# success. If a clone was required but there's still no repo, bail without
# marking complete so the retry service tries again.
if [ "$CLONE_REQUIRED" = true ] && [ ! -d "${WORKSPACE_DIR}/.git" ]; then
    log "ERROR: clone did not produce a workspace at ${WORKSPACE_DIR} (.git missing)."
    log "Not marking post-activation complete — retry service will re-run."
    exit 1
fi

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

# Mark complete only now that the workspace is confirmed present. The
# orchestrator's PostActivationRetryService treats this flag as "done" and stops
# retrying — so it must never be written on a failed/no-op clone (the guards
# above exit non-zero before reaching here in that case).
mkdir -p "$(dirname "$COMPLETION_FLAG")"
: > "$COMPLETION_FLAG"
log "Marked post-activation complete: $COMPLETION_FLAG"

log "Post-activation setup complete"
