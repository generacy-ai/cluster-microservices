#!/bin/bash
# Setup and verify speckit commands and Agency MCP server
# Usage:
#   setup-speckit.sh           # Run full setup (clone agency, build, re-run setup build)
#   setup-speckit.sh --verify  # Verify speckit is ready (exit 1 if not)

SETUP_LOG="${SETUP_LOG:-/tmp/generacy-setup.log}"

# Release channel for npm installs. GENERACY_CHANNEL is exported by
# load-cluster-config.sh in the entrypoints that invoke this script, so a
# preview cluster recovers the preview-channel packages. Mirrors
# entrypoint-orchestrator.sh's CHANNEL derivation.
CHANNEL="${GENERACY_CHANNEL:-stable}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [setup-speckit] $*"
}

verify_speckit() {
    local ok=true

    # Check for representative slash command
    if [ ! -f "$HOME/.claude/commands/specify.md" ]; then
        log "VERIFY FAIL: ~/.claude/commands/specify.md not found"
        ok=false
    fi

    # Check for Agency MCP server entry in user-level Claude config
    if [ ! -f "$HOME/.claude.json" ]; then
        log "VERIFY FAIL: ~/.claude.json not found"
        ok=false
    elif ! grep -q "agency" "$HOME/.claude.json" 2>/dev/null; then
        log "VERIFY FAIL: agency MCP server not found in ~/.claude.json"
        ok=false
    fi

    if [ "$ok" = true ]; then
        log "Speckit verification passed"
        return 0
    else
        return 1
    fi
}

# --verify mode: just check and exit
if [ "$1" = "--verify" ]; then
    verify_speckit
    exit $?
fi

# Full setup mode — recover speckit via npm (no git clone needed)
log "Installing @generacy-ai/agency-plugin-spec-kit@${CHANNEL} from npm..."
npm install -g "@generacy-ai/agency-plugin-spec-kit@${CHANNEL}" 2>>"$SETUP_LOG" || {
    log "ERROR: npm install -g @generacy-ai/agency-plugin-spec-kit@${CHANNEL} failed"
    exit 1
}
log "agency-plugin-spec-kit installed"

# Cockpit Claude Code plugin (generacy-ai/cluster-base#69). Best-effort: unlike
# speckit this is an orchestrator-only convenience and NOT required for workers
# to process phases, so a failure here (e.g. the package not yet published to
# ${CHANNEL}) must not fail speckit recovery. The `generacy setup build` re-run
# below wires /cockpit:* from it (G-S5) exactly as it does for speckit.
log "Installing @generacy-ai/claude-plugin-cockpit@${CHANNEL} from npm (best-effort)..."
npm install -g "@generacy-ai/claude-plugin-cockpit@${CHANNEL}" 2>>"$SETUP_LOG" \
    && log "claude-plugin-cockpit installed" \
    || log "WARNING: npm install -g @generacy-ai/claude-plugin-cockpit@${CHANNEL} failed — /cockpit:* may be unavailable (see $SETUP_LOG)"

# Re-run generacy setup build to trigger Phase 4 (copies command files)
if command -v generacy >/dev/null 2>&1; then
    log "Re-running generacy setup build..."
    generacy setup build 2>>"$SETUP_LOG" || {
        log "ERROR: generacy setup build failed"
        exit 1
    }
fi

# Verify the result
if verify_speckit; then
    log "Setup complete — speckit is ready"
else
    log "WARNING: Setup completed but verification failed"
    exit 1
fi
