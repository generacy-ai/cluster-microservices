#!/bin/bash
# Seed this container's ~/.claude.json from the read-only cluster seed.
#
# Clusters used to bind the operator's live ~/.claude.json read-write into the
# orchestrator and every worker. That file is per-HOST, not per-cluster, so all
# clusters on a machine shared one config — and `generacy setup build` writes an
# absolute, image-flavour-specific agency CLI path into `mcpServers.agency`.
# Whichever cluster bootstrapped last silently overwrote that entry for every
# other cluster, leaving e.g. a source-build cluster pointing at a
# /shared-packages path its containers do not have. The only visible symptom was
# an Agency MCP server that failed to start, so speckit commands quietly fell
# back to raw bash.
#
# The scaffolder now mounts a filtered seed read-only at /seed/claude.json and
# each container merges it here, so nothing writes through to a shared file. The
# key filter below is belt-and-braces: the scaffolder already filters, but a
# hand-written compose may mount the raw host file (tetrad-development does).
#
# Seed ONCE per container, tracked by a marker rather than by the absence of
# ~/.claude.json: the base image ships a small stub at that path (installMethod,
# migrationVersion, a build-time userID), so an existence check silently skipped
# the seed on every container and the operator's account metadata never arrived.
# The marker lives in the container layer, NOT in ~/.claude (a shared named
# volume), so it is per-container and resets when the container is recreated.
#
# No-ops when no seed is mounted, so this is safe on a compose file that still
# binds ~/.claude.json directly.

SEED_PATH="${CLAUDE_CONFIG_SEED:-/seed/claude.json}"
TARGET_PATH="${HOME}/.claude.json"
MARKER_PATH="${HOME}/.claude-config-seeded"

seed_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [seed-claude-config] $*"
}

if [ -f "$MARKER_PATH" ]; then
    seed_log "Already seeded this container — leaving ${TARGET_PATH} alone"
    exit 0
fi

if [ ! -f "$SEED_PATH" ]; then
    # Nothing to seed from. Claude Code creates its own config on first run;
    # this is not an error, just an unseeded container.
    seed_log "No seed at ${SEED_PATH} — starting with an empty Claude config"
    exit 0
fi

# Merge, rather than copy, so anything the image or a previous boot put in the
# target survives. Only account/onboarding keys are taken from the seed:
#
#   mcpServers  — absolute, image-flavour-specific paths. Copying these is the
#                 bug this whole change exists to fix; each container writes its
#                 own (orchestrator via `generacy setup build`, worker via
#                 bootstrap-worker.sh).
#   projects    — the operator's per-directory history, keyed by host paths that
#                 do not exist in a container, and most of the file's bulk.
#   machineID   — each container should identify as itself.
#   cached*     — feature-flag and experiment caches the CLI refetches.
#
# Auth is not here: tokens live in ~/.claude/.credentials.json, a separate
# per-cluster volume. Seeding a copy cannot break login.
if SEED_PATH="$SEED_PATH" TARGET_PATH="$TARGET_PATH" node <<'NODE'
const fs = require('node:fs');

const SEED_KEYS = [
  'oauthAccount',
  'userID',
  'hasCompletedOnboarding',
  'lastOnboardingVersion',
  'installMethod',
  'autoUpdates',
  'theme',
];

const read = (path) => {
  try {
    return JSON.parse(fs.readFileSync(path, 'utf-8'));
  } catch {
    return {};
  }
};

const seed = read(process.env.SEED_PATH);
const target = read(process.env.TARGET_PATH);

for (const key of SEED_KEYS) {
  if (seed[key] !== undefined) {
    target[key] = seed[key];
  }
}

fs.writeFileSync(process.env.TARGET_PATH, JSON.stringify(target, null, 2));
NODE
then
    chmod 0600 "$TARGET_PATH" 2>/dev/null || true
    touch "$MARKER_PATH"
    seed_log "Seeded ${TARGET_PATH} from ${SEED_PATH}"
else
    seed_log "WARNING: could not merge ${SEED_PATH} into ${TARGET_PATH}; continuing"
fi

exit 0
