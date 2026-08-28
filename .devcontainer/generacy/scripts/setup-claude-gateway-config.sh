#!/bin/bash
# Provision the second Claude config dir used by gateway-routed launches.
#
# A workflow launch whose resolved model name contains "/" (openrouter/qwen/...)
# is spawned with CLAUDE_CONFIG_DIR=/home/node/.claude-gateway
# (generacy-ai/generacy#1198). CLAUDE_CONFIG_DIR relocates settings,
# .claude.json, commands/, plugins/, sessions and credentials together, so that
# directory needs everything the subscription dir has, plus a settings.json
# pointing at the in-cluster gateway. The launch plugin refuses to spawn if
# <dir>/settings.json is missing rather than let Claude Code silently fall back
# to the subscription config.
#
# No-op when GENERACY_LLM_GATEWAY_URL is unset — a cluster without a gateway is
# byte-for-byte unchanged.
#
# ORDERING: run this at the END of bootstrap, NOT next to seed-claude-config.sh.
# seed-claude-config.sh runs as step 0 of every entrypoint, before anything
# writes ~/.claude.json; the MCP registrations arrive much later — the
# orchestrator registers cockpit directly and `generacy setup build` writes
# mcpServers.agency on the orchestrator, the workers and the post-activation
# hook. Copying .claude.json before those run yields a gateway session with no
# MCP servers, so speckit silently falls back to bash — the exact failure mode
# seed-claude-config.sh exists to prevent. The three entrypoints therefore
# invoke this script after their `generacy setup` block. Re-run it after any
# later `generacy setup build`.
#
# Idempotent and re-runnable. Ported from the tetrad-development dev cluster
# (generacy-ai/tetrad-development#110); see generacy-ai/cluster-base#90 and the
# "LLM gateway" design in tetrad-development's
# docs/llm-gateway-model-routing-plan.md.

set -u

GATEWAY_DIR="${GENERACY_CLAUDE_GATEWAY_CONFIG_DIR:-${HOME}/.claude-gateway}"
CLAUDE_DIR="${HOME}/.claude"
SOURCE_CLAUDE_JSON="${HOME}/.claude.json"

gw_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [setup-claude-gateway-config] $*"
}

# -- 0. Opt-out ---------------------------------------------------------------
if [ -z "${GENERACY_LLM_GATEWAY_URL:-}" ]; then
    gw_log "GENERACY_LLM_GATEWAY_URL unset — no gateway on this cluster, skipping"
    exit 0
fi

if [ -z "${GENERACY_LLM_GATEWAY_TOKEN:-}" ]; then
    # Write the dir anyway: a gateway-shaped model should fail with the
    # gateway's own 401 rather than the launch plugin's "dir not provisioned"
    # error, which would point at the wrong problem. `generacy doctor` reports
    # the missing token explicitly.
    gw_log "WARNING: GENERACY_LLM_GATEWAY_URL is set but GENERACY_LLM_GATEWAY_TOKEN is empty — gateway calls will 401"
fi

# -- 1. Directory -------------------------------------------------------------
# 0770, owned by the container user. Mode matters: workflow subprocesses run as
# uid 1001 (generacy-workflow) whenever the phase resolves a credhelper role,
# and as uid 1000 (node) otherwise — see agent-launcher.ts, which sets uid/gid
# only when request.credentials is present. uid 1001's gid IS node, so group
# access covers both; 0700 would break every credhelper-role launch.
#
# Group-WRITE (not just read) because Claude Code writes session and history
# state into CLAUDE_CONFIG_DIR, and a uid-1001 launch has to be able to.
#
# Not world-readable, unlike ~/.claude: this dir holds the gateway bearer token.
if ! mkdir -p "$GATEWAY_DIR"; then
    gw_log "ERROR: could not create ${GATEWAY_DIR}"
    exit 1
fi
chmod 0770 "$GATEWAY_DIR" 2>/dev/null || true

# -- 2. settings.json ---------------------------------------------------------
# Written via node for correct JSON escaping of the token. Deliberately does
# NOT set "model": the subscription dir's settings.json may pin a Claude model,
# which would be a nonsense default here — the launch always passes --model,
# and an interactive session in this dir should fall back to the CLI default
# rather than name a Claude model the gateway may not route.
#
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: no telemetry/autoupdate chatter to
#   Anthropic from a session that is not talking to Anthropic.
# CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: some anthropic-beta headers 400 on
#   non-Anthropic upstreams.
SETTINGS_PATH="${GATEWAY_DIR}/settings.json"
SETTINGS_TMP="${SETTINGS_PATH}.tmp.$$"

if SETTINGS_TMP="$SETTINGS_TMP" node <<'NODE'
const fs = require('node:fs');

const settings = {
  env: {
    ANTHROPIC_BASE_URL: process.env.GENERACY_LLM_GATEWAY_URL,
    ANTHROPIC_AUTH_TOKEN: process.env.GENERACY_LLM_GATEWAY_TOKEN ?? '',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: '1',
  },
  permissions: { defaultMode: 'bypassPermissions' },
};

fs.writeFileSync(process.env.SETTINGS_TMP, JSON.stringify(settings, null, 2) + '\n', { mode: 0o640 });
NODE
then
    chmod 0640 "$SETTINGS_TMP" 2>/dev/null || true
    mv -f "$SETTINGS_TMP" "$SETTINGS_PATH"
    gw_log "Wrote ${SETTINGS_PATH} (base URL: ${GENERACY_LLM_GATEWAY_URL})"
else
    rm -f "$SETTINGS_TMP"
    gw_log "ERROR: could not write ${SETTINGS_PATH} — gateway launches will fail fast"
    exit 1
fi

# -- 3. commands/ and plugins/ symlinks ---------------------------------------
# Symlinked, not copied, so speckit slash commands and plugins stay in step
# with the subscription dir (setup-speckit.sh / `generacy setup build` refresh
# ~/.claude/commands mid-bootstrap, and the agency plugin set is installed into
# ~/.claude/plugins).
#
# `ln -sfn` matters: without -n, relinking a symlink that already points at a
# directory creates <link>/<target> inside it instead of replacing the link. A
# dangling link is fine and expected — if ~/.claude/commands is populated later
# in bootstrap, the link resolves then.
for sub in commands plugins; do
    link="${GATEWAY_DIR}/${sub}"
    target="${CLAUDE_DIR}/${sub}"

    # A real directory here (e.g. created by a Claude Code run before this
    # script first ran) would make `ln -sfn` nest instead of replace.
    if [ -d "$link" ] && [ ! -L "$link" ]; then
        gw_log "Replacing real directory ${link} with a symlink to ${target}"
        rm -rf "$link"
    fi

    if ln -sfn "$target" "$link"; then
        [ -e "$link" ] || gw_log "NOTE: ${target} does not exist yet — ${sub} link will resolve once bootstrap populates it"
    else
        gw_log "WARNING: could not link ${link} -> ${target}"
    fi
done
gw_log "Linked commands/ and plugins/ to ${CLAUDE_DIR}"

# -- 4. .claude.json (MCP registrations) --------------------------------------
# Copied, not symlinked: Claude Code rewrites this file at runtime (history,
# project state), and a symlink would let a gateway session write through into
# the subscription config — including its own session/onboarding state.
#
# oauthAccount is dropped: this session authenticates with a gateway bearer
# token, not the Claude subscription, so presenting subscription account
# metadata is at best misleading.
#
# Copy only when the source is newer, so a hand-edit in the gateway dir (an
# extra MCP server, say) survives a re-run while `generacy setup build`'s
# mcpServers rewrite still propagates.
TARGET_CLAUDE_JSON="${GATEWAY_DIR}/.claude.json"

if [ ! -f "$SOURCE_CLAUDE_JSON" ]; then
    gw_log "NOTE: ${SOURCE_CLAUDE_JSON} does not exist — gateway sessions will start with no MCP servers"
elif [ -f "$TARGET_CLAUDE_JSON" ] && [ ! "$SOURCE_CLAUDE_JSON" -nt "$TARGET_CLAUDE_JSON" ]; then
    gw_log "Keeping ${TARGET_CLAUDE_JSON} — not older than ${SOURCE_CLAUDE_JSON}"
else
    CLAUDE_JSON_TMP="${TARGET_CLAUDE_JSON}.tmp.$$"
    if SOURCE_CLAUDE_JSON="$SOURCE_CLAUDE_JSON" CLAUDE_JSON_TMP="$CLAUDE_JSON_TMP" node <<'NODE'
const fs = require('node:fs');

const source = JSON.parse(fs.readFileSync(process.env.SOURCE_CLAUDE_JSON, 'utf-8'));
delete source.oauthAccount;

fs.writeFileSync(process.env.CLAUDE_JSON_TMP, JSON.stringify(source, null, 2) + '\n', { mode: 0o640 });
NODE
    then
        chmod 0640 "$CLAUDE_JSON_TMP" 2>/dev/null || true
        mv -f "$CLAUDE_JSON_TMP" "$TARGET_CLAUDE_JSON"
        gw_log "Copied ${SOURCE_CLAUDE_JSON} -> ${TARGET_CLAUDE_JSON} (minus oauthAccount)"
    else
        rm -f "$CLAUDE_JSON_TMP"
        # Non-fatal: a gateway session without MCP servers still runs, it just
        # falls back to bash for speckit. Better than blocking the entrypoint.
        gw_log "WARNING: could not copy ${SOURCE_CLAUDE_JSON} (unparseable?) — gateway sessions will have no MCP servers"
    fi
fi

gw_log "Gateway config dir ready at ${GATEWAY_DIR}"
exit 0
