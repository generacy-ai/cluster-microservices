#!/bin/bash
# Tests for .devcontainer/generacy/scripts/setup-claude-gateway-config.sh
# (generacy-ai/cluster-base#90).
#
# Plain bash, no framework: cluster-base has no test runner, no CI workflow and
# no node/pnpm project at the root, so a self-contained script that any
# container or dev machine with bash + node can run is the lowest-friction
# option. Run it from anywhere:
#
#     bash tests/setup-claude-gateway-config.test.sh
#
# Every case runs against a throwaway HOME, so nothing here touches the real
# ~/.claude or ~/.claude-gateway. Requires `node` (the script under test shells
# out to it for JSON).
#
# Covered: the no-op branch, first provisioning (dir/file modes, settings
# contents, symlinks, oauthAccount stripping), idempotency across repeated
# runs, a real directory sitting at a symlink path, the mtime staleness rule
# for the .claude.json copy, and the missing-token branch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/../.devcontainer/generacy/scripts/setup-claude-gateway-config.sh"

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
    echo "FATAL: script under test not found at ${SCRIPT_UNDER_TEST}"
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "FATAL: node is required (the script under test uses it for JSON)"
    exit 1
fi

PASS=0
FAIL=0
CURRENT_CASE=""

ok() {
    PASS=$((PASS + 1))
    echo "  ok   - $1"
}

not_ok() {
    FAIL=$((FAIL + 1))
    echo "  FAIL - $1"
    [ $# -gt 1 ] && echo "         $2"
}

assert() {
    # assert <description> <condition-exit-code-producing-command...>
    local desc="$1"
    shift
    if "$@"; then
        ok "$desc"
    else
        not_ok "$desc" "command failed: $*"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$desc"
    else
        not_ok "$desc" "expected [${expected}], got [${actual}]"
    fi
}

testcase() {
    CURRENT_CASE="$1"
    echo ""
    echo "# ${CURRENT_CASE}"
}

# Fresh throwaway HOME. Echoes the path; callers assign it.
new_home() {
    mktemp -d "${TMPDIR:-/tmp}/gateway-config-test.XXXXXX"
}

# Run the script under test with a given HOME and env. Stdout+stderr land in
# $RUN_OUTPUT, exit status in $RUN_STATUS.
#
# The gateway vars are unset first so the suite is hermetic: a developer running
# this inside a cluster that HAS a gateway would otherwise inherit a real
# GENERACY_LLM_GATEWAY_TOKEN and silently skip the missing-token case. `env`
# applies -u before the NAME=VALUE arguments, so a value passed by the caller
# still wins.
run_script() {
    local home="$1"
    shift
    RUN_OUTPUT="$(env -u GENERACY_LLM_GATEWAY_URL \
                      -u GENERACY_LLM_GATEWAY_TOKEN \
                      -u GENERACY_CLAUDE_GATEWAY_CONFIG_DIR \
                      HOME="$home" "$@" bash "$SCRIPT_UNDER_TEST" 2>&1)"
    RUN_STATUS=$?
    return 0
}

json_get() {
    # json_get <file> <node expression over `data`>
    node -e '
        const fs = require("node:fs");
        const data = JSON.parse(fs.readFileSync(process.argv[1], "utf-8"));
        const value = eval(process.argv[2]);
        process.stdout.write(value === undefined ? "<undefined>" : String(value));
    ' "$1" "$2"
}

# Mode + name + symlink target for every entry in a directory, sorted — the
# fingerprint the idempotency check compares before and after re-runs.
dir_fingerprint() {
    find "$1" -maxdepth 1 -printf '%M %f -> %l\n' | sort
}

mode_of() {
    stat -c '%a' "$1" 2>/dev/null || echo "<missing>"
}

seed_claude_json() {
    # A stand-in for what `generacy setup build` + the cockpit registration
    # leave in ~/.claude.json.
    cat >"${1}/.claude.json" <<'JSON'
{
  "oauthAccount": { "emailAddress": "operator@example.com" },
  "mcpServers": { "agency": { "command": "agency-mcp" } },
  "userID": "abc123"
}
JSON
}

# -----------------------------------------------------------------------------
testcase "no-op when GENERACY_LLM_GATEWAY_URL is unset"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" GENERACY_LLM_GATEWAY_URL= GENERACY_LLM_GATEWAY_TOKEN=
assert_eq "exits 0" "0" "$RUN_STATUS"
assert "does not create the gateway dir" [ ! -e "${HOME_DIR}/.claude-gateway" ]
assert "says why it skipped" grep -q "GENERACY_LLM_GATEWAY_URL unset" <<<"$RUN_OUTPUT"
rm -rf "$HOME_DIR"

# An empty-string URL is the same as unset (compose passes through empty vars).
HOME_DIR="$(new_home)"
run_script "$HOME_DIR" GENERACY_LLM_GATEWAY_URL=""
assert_eq "empty URL also exits 0" "0" "$RUN_STATUS"
assert "empty URL creates nothing" [ ! -e "${HOME_DIR}/.claude-gateway" ]
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "provisions the gateway dir when the URL is set"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
mkdir -p "${HOME_DIR}/.claude/commands" "${HOME_DIR}/.claude/plugins"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
GW="${HOME_DIR}/.claude-gateway"

assert_eq "exits 0" "0" "$RUN_STATUS"
assert "creates the gateway dir" [ -d "$GW" ]
assert_eq "dir is 0770 (uid 1001 launches need group rwx)" "770" "$(mode_of "$GW")"
assert "writes settings.json" [ -f "${GW}/settings.json" ]
assert_eq "settings.json is 0640" "640" "$(mode_of "${GW}/settings.json")"

assert_eq "ANTHROPIC_BASE_URL points at the gateway" \
    "http://llm-gateway:8080/anthropic" \
    "$(json_get "${GW}/settings.json" 'data.env.ANTHROPIC_BASE_URL')"
assert_eq "ANTHROPIC_AUTH_TOKEN carries the gateway token" \
    "sk-bf-testtoken" \
    "$(json_get "${GW}/settings.json" 'data.env.ANTHROPIC_AUTH_TOKEN')"
assert_eq "nonessential traffic disabled" "1" \
    "$(json_get "${GW}/settings.json" 'data.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')"
assert_eq "experimental betas disabled" "1" \
    "$(json_get "${GW}/settings.json" 'data.env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS')"
assert_eq "permissions default to bypassPermissions" "bypassPermissions" \
    "$(json_get "${GW}/settings.json" 'data.permissions.defaultMode')"
assert_eq "no model is pinned" "<undefined>" \
    "$(json_get "${GW}/settings.json" 'data.model')"

assert "commands is a symlink" [ -L "${GW}/commands" ]
assert "plugins is a symlink" [ -L "${GW}/plugins" ]
assert_eq "commands points at ~/.claude/commands" \
    "${HOME_DIR}/.claude/commands" "$(readlink "${GW}/commands")"
assert_eq "plugins points at ~/.claude/plugins" \
    "${HOME_DIR}/.claude/plugins" "$(readlink "${GW}/plugins")"

assert "copies .claude.json" [ -f "${GW}/.claude.json" ]
assert "the copy is a real file, not a symlink" [ ! -L "${GW}/.claude.json" ]
assert_eq ".claude.json copy is 0640" "640" "$(mode_of "${GW}/.claude.json")"
assert_eq "oauthAccount is dropped" "<undefined>" \
    "$(json_get "${GW}/.claude.json" 'data.oauthAccount')"
assert_eq "mcpServers survive the copy" "agency-mcp" \
    "$(json_get "${GW}/.claude.json" 'data.mcpServers.agency.command')"
assert "leaves no temp files behind" \
    bash -c "! ls ${GW}/*.tmp.* >/dev/null 2>&1"
assert "does not write through to the subscription config" \
    grep -q "oauthAccount" "${HOME_DIR}/.claude.json"

# -----------------------------------------------------------------------------
testcase "is idempotent across repeated runs (same HOME as above)"
# -----------------------------------------------------------------------------
BEFORE="$(dir_fingerprint "$GW")"
for run in 2 3; do
    run_script "$HOME_DIR" \
        GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
        GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
    assert_eq "run ${run} exits 0" "0" "$RUN_STATUS"
done
AFTER="$(dir_fingerprint "$GW")"
assert_eq "directory listing is unchanged after 3 runs" "$BEFORE" "$AFTER"
assert "commands is still a symlink (ln -sfn, no nesting)" [ -L "${GW}/commands" ]
assert "plugins is still a symlink" [ -L "${GW}/plugins" ]
assert "no nested commands/commands" [ ! -e "${GW}/commands/commands" ]
assert "no nested plugins/plugins" [ ! -e "${GW}/plugins/plugins" ]
assert_eq "exactly two symlinks in the dir" "2" \
    "$(find "$GW" -maxdepth 1 -type l | wc -l | tr -d ' ')"
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "replaces a real directory sitting at a symlink path"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
mkdir -p "${HOME_DIR}/.claude/commands" "${HOME_DIR}/.claude/plugins"
mkdir -p "${HOME_DIR}/.claude-gateway/commands"
touch "${HOME_DIR}/.claude-gateway/commands/stray.md"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
GW="${HOME_DIR}/.claude-gateway"
assert_eq "exits 0" "0" "$RUN_STATUS"
assert "commands became a symlink" [ -L "${GW}/commands" ]
assert "no nesting under the link" [ ! -e "${GW}/commands/commands" ]
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "dangling symlinks when ~/.claude is not populated yet"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
GW="${HOME_DIR}/.claude-gateway"
assert_eq "still exits 0" "0" "$RUN_STATUS"
assert "commands link exists even though the target does not" [ -L "${GW}/commands" ]
assert "notes the unresolved link" grep -q "will resolve once bootstrap populates it" <<<"$RUN_OUTPUT"
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "no ~/.claude.json at all"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
GW="${HOME_DIR}/.claude-gateway"
assert_eq "exits 0 (settings.json is what gates the launch)" "0" "$RUN_STATUS"
assert "settings.json is still written" [ -f "${GW}/settings.json" ]
assert "no .claude.json copy" [ ! -e "${GW}/.claude.json" ]
assert "says so" grep -q "no MCP servers" <<<"$RUN_OUTPUT"
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "staleness rule for the .claude.json copy"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
GW="${HOME_DIR}/.claude-gateway"

# A hand-edit in the gateway dir that is NEWER than the source survives.
node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const data = JSON.parse(fs.readFileSync(p, "utf-8"));
    data.mcpServers.handAdded = { command: "hand-added" };
    fs.writeFileSync(p, JSON.stringify(data, null, 2));
' "${GW}/.claude.json"
touch -d '2020-01-01 00:00:00' "${HOME_DIR}/.claude.json"
touch -d '2021-01-01 00:00:00' "${GW}/.claude.json"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
assert_eq "a newer hand-edit is preserved" "hand-added" \
    "$(json_get "${GW}/.claude.json" 'data.mcpServers.handAdded.command')"
assert "logs that it kept the copy" grep -q "Keeping" <<<"$RUN_OUTPUT"

# A `generacy setup build` rewrite (source newer) propagates.
node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const data = JSON.parse(fs.readFileSync(p, "utf-8"));
    data.mcpServers.agency = { command: "/shared-packages/agency-mcp" };
    fs.writeFileSync(p, JSON.stringify(data, null, 2));
' "${HOME_DIR}/.claude.json"
touch -d '2022-01-01 00:00:00' "${HOME_DIR}/.claude.json"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken"
assert_eq "a newer source propagates" "/shared-packages/agency-mcp" \
    "$(json_get "${GW}/.claude.json" 'data.mcpServers.agency.command')"
assert_eq "the hand-edit is clobbered by the newer source (expected)" "<undefined>" \
    "$(json_get "${GW}/.claude.json" 'data.mcpServers.handAdded')"
assert_eq "oauthAccount still dropped on re-copy" "<undefined>" \
    "$(json_get "${GW}/.claude.json" 'data.oauthAccount')"
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "URL set but token missing"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic"
GW="${HOME_DIR}/.claude-gateway"
assert_eq "exits 0 so the gateway's own 401 is what surfaces" "0" "$RUN_STATUS"
assert "warns about the empty token" grep -q "GENERACY_LLM_GATEWAY_TOKEN is empty" <<<"$RUN_OUTPUT"
assert "still provisions settings.json" [ -f "${GW}/settings.json" ]
assert_eq "auth token is an empty string, not null/undefined" "" \
    "$(json_get "${GW}/settings.json" 'data.env.ANTHROPIC_AUTH_TOKEN')"
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
testcase "honours GENERACY_CLAUDE_GATEWAY_CONFIG_DIR"
# -----------------------------------------------------------------------------
HOME_DIR="$(new_home)"
seed_claude_json "$HOME_DIR"
run_script "$HOME_DIR" \
    GENERACY_LLM_GATEWAY_URL="http://llm-gateway:8080/anthropic" \
    GENERACY_LLM_GATEWAY_TOKEN="sk-bf-testtoken" \
    GENERACY_CLAUDE_GATEWAY_CONFIG_DIR="${HOME_DIR}/custom-gateway-dir"
assert_eq "exits 0" "0" "$RUN_STATUS"
assert "uses the override path" [ -f "${HOME_DIR}/custom-gateway-dir/settings.json" ]
assert "leaves the default path alone" [ ! -e "${HOME_DIR}/.claude-gateway" ]
rm -rf "$HOME_DIR"

# -----------------------------------------------------------------------------
echo ""
echo "-----------------------------------------------"
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
