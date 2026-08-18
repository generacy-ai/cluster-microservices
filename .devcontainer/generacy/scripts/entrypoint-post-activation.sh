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
#   5. Restart the cluster's containers ONCE (generacy-ai/cluster-base#59) so
#      every entrypoint re-runs with credentials + repo present:
#        - workers re-source wizard-credentials.env, get GH_TOKEN, and clone;
#        - the orchestrator re-resolves monitored repos + cluster identity and
#          (re)enables the label monitor it had disabled at empty-boot.
#      This is the "restart-based" fix: on a brand-new wizard cluster the
#      containers boot BEFORE post-activation delivers creds/repo, latch the
#      empty state, and nothing re-runs setup — so we trigger that re-run here.
#
# Idempotent — safe to invoke multiple times. The restart in step 5 is the one
# exception that must fire only once; it is gated on a one-shot marker file (see
# RESTART_DONE_MARKER below) so the post-restart re-run of this hook does not
# loop the cluster.
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

# One-shot marker for the step-5 container restart (generacy-ai/cluster-base#59).
# Lives alongside the completion flag in /var/lib/generacy: that path is on the
# orchestrator's writable layer, so it SURVIVES a `docker restart` (same
# container, layer preserved) but is RESET on `docker compose down && up` (fresh
# container) — exactly the lifecycle we want. A fresh wizard cluster has no
# marker → we restart once; the post-restart re-run of this hook sees the marker
# → skips the restart, so the cluster never loops.
RESTART_DONE_MARKER="${POST_ACTIVATION_RESTART_MARKER:-/var/lib/generacy/post-activation-restart-done}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-activation] $*"
}

log "Starting post-activation setup..."

# Wizard-mode clusters reach `generacy setup build` through this path rather
# than the orchestrator entrypoint, so seed here too. No-ops if already seeded.
bash /usr/local/bin/seed-claude-config.sh || true

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

    # Re-assert git credential wiring: `setup auth` / `setup workspace` replace
    # the JIT helper (Step 1) with static wiring built from the 1-hour wizard
    # GH_TOKEN (`credential.helper store` + `gh auth setup-git`). The
    # orchestrator's git-helper-guard would heal this within its poll interval,
    # but healing eagerly closes the drift window entirely. Fixed at the source
    # in generacy-ai/generacy#1105; kept here for older generacy versions.
    bash /usr/local/bin/setup-credentials.sh
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

# Step 5 (generacy-ai/cluster-base#59): re-initialize the cluster's containers
# once, now that creds + repo are present, so the empty-boot state every
# entrypoint latched gets re-run.
#
# Why a restart and not in-process re-resolution: the orchestrator resolves
# monitored repos + cluster identity once at server start and disables the
# label monitor when no repo is cloned yet; the workers source
# wizard-credentials.env + run setup-credentials.sh once at entrypoint,
# pre-activation. None of those re-read their inputs while running. Restarting
# the containers re-runs every entrypoint from the top with creds + repo in
# place — the simplest fix that lives entirely in this repo.
#
# This runs from inside the orchestrator, which has the host docker socket
# (DOCKER_HOST=unix:///var/run/docker-host.sock) and already manages the worker
# containers, so it can restart its siblings and itself.
restart_cluster_containers() {
    # Already restarted on a prior run of this hook (e.g. the post-restart
    # re-run, or a PostActivationRetryService retry) — do not loop the cluster.
    if [ -e "$RESTART_DONE_MARKER" ]; then
        log "Container restart already performed ($RESTART_DONE_MARKER present) — skipping."
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log "WARNING: docker CLI not available — cannot auto-restart containers."
        log "WARNING: restart the orchestrator and worker containers manually to finish activation."
        return 0
    fi

    # cluster-microservices divergence from cluster-base: here the docker CLI's
    # default context is the in-container DinD daemon (setup-docker-dind.sh runs
    # `docker context use default`), NOT the host daemon. The sibling
    # orchestrator/worker containers are owned by the HOST daemon, reachable via
    # the DooD socket /var/run/docker-host.sock — the same socket the
    # orchestrator's worker-scaler and control-plane target. Point our docker
    # calls at it so inspect/ps/restart hit the daemon that actually owns these
    # containers; otherwise they'd query DinD, find no siblings, and silently
    # no-op. (cluster-base sets ENV DOCKER_HOST to this value image-wide, so it
    # has no such block — this is the microservices-specific adaptation.)
    HOST_DOCKER_SOCK="${HOST_DOCKER_SOCK:-/var/run/docker-host.sock}"
    if [ -S "$HOST_DOCKER_SOCK" ]; then
        export DOCKER_HOST="unix://${HOST_DOCKER_SOCK}"
        log "Targeting host docker daemon for container restart ($DOCKER_HOST)"
    else
        log "WARNING: host docker socket ${HOST_DOCKER_SOCK} not present — docker calls will hit the default (DinD) context and may not find sibling containers."
    fi

    # Identify ourselves and our compose project from our own container labels.
    # `hostname` is the container's short id under compose (no custom hostname
    # is set in docker-compose.yml), which `docker inspect` accepts.
    local self_container compose_project
    self_container="$(hostname)"
    compose_project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$self_container" 2>/dev/null || true)"

    if [ -z "$compose_project" ]; then
        log "WARNING: could not determine compose project from container labels — cannot auto-restart containers."
        log "WARNING: restart the orchestrator and worker containers manually to finish activation."
        return 0
    fi

    # Restart the worker containers first (they only need creds + repo, not a
    # fresh orchestrator). Match by the standard compose labels for this project.
    local worker_ids
    worker_ids="$(docker ps -q \
        --filter "label=com.docker.compose.project=${compose_project}" \
        --filter "label=com.docker.compose.service=worker" 2>/dev/null || true)"

    if [ -n "$worker_ids" ]; then
        # shellcheck disable=SC2086 — word-splitting the id list is intended.
        log "Restarting worker containers: $(echo $worker_ids | tr '\n' ' ')"
        # shellcheck disable=SC2086
        docker restart $worker_ids >/dev/null 2>&1 \
            || log "WARNING: one or more worker restarts failed — check 'docker ps'."
    else
        log "No worker containers found for project '${compose_project}' — nothing to restart."
    fi

    # Write the marker BEFORE restarting ourselves: once the orchestrator
    # restarts, the watcher re-fires this hook, which must find the marker and
    # skip this whole block. (The restart kills this process, so anything after
    # the self-restart line will not run.)
    : > "$RESTART_DONE_MARKER"
    log "Wrote restart marker: $RESTART_DONE_MARKER"

    # Restart ourselves last. This re-runs entrypoint-orchestrator.sh with the
    # repo cloned and GH_USERNAME populated, so it resolves cluster identity and
    # re-enables the label monitor. SIGTERM lands here and the process exits.
    log "Restarting orchestrator container '${self_container}' to re-resolve repos + identity and enable the label monitor..."
    docker restart "$self_container" >/dev/null 2>&1 \
        || log "WARNING: orchestrator self-restart failed — restart the orchestrator container manually to enable the label monitor."
}

restart_cluster_containers

log "Post-activation setup complete"
