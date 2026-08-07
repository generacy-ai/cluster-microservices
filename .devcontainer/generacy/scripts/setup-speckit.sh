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

# Start the configured Agency MCP server and count the spec_kit tools it
# advertises.
#
# Checking config strings is not enough: the server can start, report a healthy
# connection to `claude mcp list`, and still advertise ZERO tools — which is
# exactly what happened when an over-strict manifest semver check rejected every
# preview-channel plugin. Speckit commands then silently degraded to raw bash
# with nothing in any log. Only a real tools/list handshake catches that.
#
# Echoes the spec_kit tool count on stdout; non-zero exit means the server could
# not be resolved or spoken to.
count_spec_kit_tools() {
    local cli
    cli=$(node -e '
      const fs = require("fs"), os = require("os"), path = require("path");
      try {
        const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".claude.json"), "utf-8"));
        const args = cfg?.mcpServers?.agency?.args;
        if (Array.isArray(args) && args[0]) process.stdout.write(args[0]);
      } catch {}
    ' 2>/dev/null)

    if [ -z "$cli" ] || [ ! -f "$cli" ]; then
        return 1
    fi

    printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
        | timeout 60 node "$cli" 2>/dev/null \
        | node -e '
            let buf = "";
            process.stdin.on("data", (d) => (buf += d));
            process.stdin.on("end", () => {
              let count = 0;
              for (const line of buf.split("\n")) {
                if (!line.trim()) continue;
                try {
                  const msg = JSON.parse(line);
                  if (msg.id === 2 && Array.isArray(msg.result?.tools)) {
                    count = msg.result.tools.filter((t) => String(t.name).startsWith("spec_kit.")).length;
                  }
                } catch {}
              }
              process.stdout.write(String(count));
            });
        ' 2>/dev/null
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

    # The check that actually matters: does the server serve spec_kit tools?
    #
    # Reported loudly but NOT fatal. The existing FATAL conditions above are
    # missing files — deterministic and unrecoverable. This one is a live
    # handshake that can fail for transient reasons (slow start, timeout), and
    # turning that into a boot failure would be a new way to brick a cluster.
    # A degraded worker that logs why beats a worker that will not start.
    local tool_count
    tool_count=$(count_spec_kit_tools)
    if [ -z "$tool_count" ]; then
        log "WARNING: could not resolve or start the agency MCP server from ~/.claude.json"
        log "WARNING: speckit commands will fall back to bash — check $SETUP_LOG"
    elif [ "$tool_count" -eq 0 ] 2>/dev/null; then
        log "WARNING: agency MCP server started but advertises 0 spec_kit tools"
        log "WARNING: a healthy MCP connection with no tools means speckit commands"
        log "WARNING: silently fall back to bash. Check plugin discovery: the server"
        log "WARNING: logs '[agency] Ignoring plugin at ...' for rejected manifests."
    else
        log "Agency MCP server advertises ${tool_count} spec_kit tools"
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
