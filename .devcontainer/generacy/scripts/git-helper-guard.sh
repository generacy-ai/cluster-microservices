#!/usr/bin/env bash
# JIT git credential-helper guard (generacy-ai/cluster-base#66).
#
# setup-credentials.sh installs a just-in-time git credential helper
# (git-credential-generacy) in wizard mode. But when a user attaches VS Code /
# code-server to the container — notably the Microsoft VS Code Server launched
# by `code tunnel`, which is what cloud clusters actually run — VS Code's
# git/GitHub integration rewrites ~/.gitconfig back to `credential.helper=store`
# plus the gh-CLI helper and caches a static `ghs_` token in ~/.git-credentials.
# That static token expires ~1h later and breaks git auth for anyone working in
# the container.
#
# Shipping VS Code default settings (see Dockerfile) only partially prevents
# this: the GitHub-extension knob (`github.gitAuthentication`) is window-scoped,
# so it can't be enforced from machine-level defaults and the user's synced
# settings can re-enable it. This guard makes the JIT helper authoritative
# regardless — it polls ~/.gitconfig and re-asserts the JIT helper whenever it
# drifts. It mirrors the `gh` JIT wrapper's philosophy: don't trust the ambient
# credential state; re-establish the JIT path on demand.
#
# Launched (backgrounded) by the orchestrator AND worker entrypoints. VS Code
# only attaches to the orchestrator, but workers proved to have their own
# clobber source: the generacy setup steps (`setup auth` / `setup workspace`)
# rewrote the same static wiring from the 1-hour wizard token, and with no
# guard running workers lost git auth an hour after activation (fixed at the
# source in generacy-ai/generacy#1105; the guard also protects against
# in-workflow tooling). Harmless anywhere: it no-ops when there is no drift
# and self-exits outside wizard mode.

set -uo pipefail

# Only meaningful in wizard mode (JIT helper). In local-dev / devcontainer mode
# setup-credentials.sh configures a static long-lived token on purpose; never
# fight that.
MODE="${GENERACY_BOOTSTRAP_MODE:-devcontainer}"
[ "$MODE" = "wizard" ] || exit 0

INTERVAL="${GIT_HELPER_GUARD_INTERVAL:-30}"
JIT_MARKER="git-credential-generacy"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [git-helper-guard] $*"; }

drifted() {
    # Drifted if the JIT helper is no longer the github.com credential helper,
    # OR a generic helper (e.g. `store`) reappeared, OR the static credentials
    # file was re-created — the hallmarks of the VS Code clobber.
    git config --global --get-all "credential.https://github.com.helper" 2>/dev/null \
        | grep -q "$JIT_MARKER" || return 0
    [ -n "$(git config --global --get-all credential.helper 2>/dev/null)" ] && return 0
    [ -e "${HOME}/.git-credentials" ] && return 0
    return 1
}

log "watching ~/.gitconfig; re-asserting JIT git helper on drift (every ${INTERVAL}s)"
while true; do
    if drifted; then
        log "git credential config drifted (VS Code clobber?) — re-asserting JIT helper"
        bash /usr/local/bin/setup-credentials.sh >/dev/null 2>&1 || true
    fi
    sleep "$INTERVAL"
done
