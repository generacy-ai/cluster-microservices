#!/bin/bash
# Configure git authentication. Called by entrypoint scripts before any git
# operations.
#
# Two regimes, keyed on GENERACY_BOOTSTRAP_MODE:
#
#   wizard  (cloud cluster) — durable JIT auth (generacy-ai/cluster-base#61).
#     git is configured to call the JIT credential helper (`git-credential-
#     generacy`, shipped in @generacy-ai/control-plane — generacy-ai/generacy
#     #766) on every operation. The helper fetches a fresh GitHub installation
#     token from the control-plane on demand (supply side: generacy-ai/
#     generacy-cloud#817), so the cloud's 1h-capped installation token can
#     never go stale mid-workflow. NO static token is seeded.
#
#   devcontainer (local dev) — static token seeding (unchanged legacy behavior).
#     Local clusters authenticate with a long-lived developer PAT from .env
#     (GH_TOKEN); they are not necessarily cloud-activated, so the JIT helper
#     (which needs the cluster API key written at activation) has no token
#     source. A developer PAT does not have the 1h installation-token expiry
#     problem, so static seeding is appropriate here.
#
# Socket routing for the JIT helper:
#   - Orchestrator / post-activation run alongside the control-plane daemon, so
#     the helper talks to it directly via the default control socket.
#   - Workers have no local control-plane; the worker entrypoint points them at
#     the git-token proxy socket (a shared volume) by exporting
#     GIT_TOKEN_SOCKET_PATH before calling this script. The proxy ships in
#     @generacy-ai/control-plane (generacy-ai/generacy#768).

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [setup-credentials] $*"
}

MODE="${GENERACY_BOOTSTRAP_MODE:-devcontainer}"

# Configure git identity if provided (sourced from the wizard / .env).
if [ -n "${GH_EMAIL:-}" ]; then
    git config --global user.email "${GH_EMAIL}"
fi
if [ -n "${GH_USERNAME:-}" ]; then
    git config --global user.name "${GH_USERNAME}"
fi

configure_jit_helper() {
    # Path to the JIT credential helper, installed into the shared-packages
    # volume by the orchestrator's package install. Overridable for tests.
    local helper_js="${GIT_CREDENTIAL_HELPER_JS:-/shared-packages/node_modules/@generacy-ai/control-plane/dist/bin/git-credential-generacy.js}"

    # Control socket the helper POSTs to. Defaults to the in-container control-
    # plane socket (correct for orchestrator + post-activation); the worker
    # entrypoint overrides this to the shared git-token proxy socket.
    local socket_path="${GIT_TOKEN_SOCKET_PATH:-/run/generacy-control-plane/control.sock}"

    # git runs a `credential.helper` whose value starts with `!` as a shell
    # command, appending the operation (get/store/erase). We inline the socket
    # path as an env assignment so routing is baked into git config and does
    # not depend on the (possibly different-uid) environment of whatever process
    # later runs git — agent workflows on workers run as a separate uid.
    local helper_cmd="!CONTROL_PLANE_SOCKET_PATH='${socket_path}' node '${helper_js}'"

    # Tear down any legacy static-token wiring so the JIT helper is the ONLY
    # credential source for github.com (idempotent across re-runs):
    #   - drop the generic `store` helper a prior version configured,
    #   - delete the static ~/.git-credentials file it wrote,
    #   - reset the per-host helper list to just the JIT helper.
    git config --global --unset-all credential.helper 2>/dev/null || true
    rm -f "${HOME}/.git-credentials"

    # An empty first entry resets git's per-host helper list, guaranteeing no
    # inherited helper (e.g. a system-level `store`) is consulted; the JIT
    # helper is then the sole entry. --replace-all collapses prior-run entries.
    git config --global --replace-all "credential.https://github.com.helper" "" 2>/dev/null || true
    git config --global --add "credential.https://github.com.helper" "${helper_cmd}"

    # Note on gists: the helper only answers for host github.com (it exits 0 for
    # any other host), so gist.github.com cannot be served a token by it. Gist
    # git auth was never covered by the old static ~/.git-credentials entry
    # either (keyed to github.com), so this is no regression. If gist auth is
    # needed later, the helper (generacy#766) must learn gist.github.com first.

    log "Git configured to authenticate via JIT credential helper (socket: ${socket_path})"
}

configure_static_token() {
    if [ -z "${GH_TOKEN:-}" ]; then
        log "WARNING: GH_TOKEN not set (local mode) — git operations requiring auth will fail"
        return 0
    fi
    # Local-dev legacy behavior: store a long-lived developer PAT.
    git config --global credential.helper store
    echo "https://${GH_USERNAME:-git}:${GH_TOKEN}@github.com" > "${HOME}/.git-credentials"
    chmod 600 "${HOME}/.git-credentials" 2>/dev/null || true
    log "Git credentials configured from static GH_TOKEN (local dev mode)"
}

if [ "$MODE" = "wizard" ]; then
    configure_jit_helper
else
    configure_static_token
fi
