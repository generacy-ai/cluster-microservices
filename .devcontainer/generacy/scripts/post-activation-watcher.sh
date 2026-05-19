#!/bin/bash
# Background watcher: waits for a sentinel file, then runs
# entrypoint-post-activation.sh. Spawned by entrypoint-orchestrator.sh in
# wizard mode (GENERACY_BOOTSTRAP_MODE=wizard).
#
# Trigger contract
#   Anything that needs to fire the post-activation hook creates the sentinel
#   file. This is the stable contract this script exposes. Examples:
#     - control-plane bootstrap-complete handler (generacy-cloud#532) writes
#       the sentinel after persisting credentials
#     - manual test:  docker compose exec orchestrator touch <trigger-path>
#
# Usage:
#   post-activation-watcher.sh [trigger-path]
#
# Defaults / env overrides:
#   POST_ACTIVATION_TRIGGER       sentinel path (default /tmp/generacy-bootstrap-complete)
#   POST_ACTIVATION_POLL_INTERVAL seconds between polls (default 2)
#   POST_ACTIVATION_LOG           log file for the hook output (default /tmp/post-activation.log)
#
# Idempotent: if the sentinel already exists at startup the hook fires
# immediately; entrypoint-post-activation.sh is itself idempotent so repeated
# triggers (e.g. after an orchestrator restart) are safe.

set -u

TRIGGER="${1:-${POST_ACTIVATION_TRIGGER:-/tmp/generacy-bootstrap-complete}}"
POLL_INTERVAL="${POST_ACTIVATION_POLL_INTERVAL:-2}"
LOG_FILE="${POST_ACTIVATION_LOG:-/tmp/post-activation.log}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-activation-watcher] $*"
}

log "Watching ${TRIGGER} (poll every ${POLL_INTERVAL}s)..."

while [ ! -e "${TRIGGER}" ]; do
    sleep "${POLL_INTERVAL}"
done

log "Trigger detected — running entrypoint-post-activation.sh (output: ${LOG_FILE})"

bash /usr/local/bin/entrypoint-post-activation.sh >>"${LOG_FILE}" 2>&1
rc=$?

if [ "${rc}" -eq 0 ]; then
    log "Post-activation completed successfully"
else
    log "ERROR: post-activation exited ${rc} — see ${LOG_FILE}"
fi

exit "${rc}"
