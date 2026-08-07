#!/bin/bash
# Entrypoint for the Generacy orchestrator container
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [orchestrator] $*"
}

log "Starting orchestrator setup..."

# Give this container its own ~/.claude.json before anything writes to it.
# Must run before `generacy setup auth` / `setup build`, which populate
# mcpServers — see seed-claude-config.sh for why the file is no longer shared.
bash /usr/local/bin/seed-claude-config.sh || true

# Start Docker-in-Docker daemon and configure host context
bash /usr/local/bin/setup-docker-dind.sh

# Fix mounted host docker socket permissions.
#
# This container's DEFAULT docker context is the in-container DinD daemon, but
# the sibling orchestrator/worker containers are owned by the HOST daemon —
# so the worker-scale lifecycle action and entrypoint-post-activation.sh both
# target /var/run/docker-host.sock explicitly via DOCKER_HOST. That socket
# arrives with the host's docker group GID, which does not match the arbitrary
# GID assigned by the in-container `groupadd` and is not predictable across
# hosts (Debian, Docker Desktop and WSL2 all differ). Without this, the node
# user gets EACCES on the socket and worker-scale fails.
#
# cluster-base has carried this since its #45/#47; it was dropped here during
# an earlier cluster-base sync whose conflict resolution replaced this region
# wholesale with the DinD call, and the host-socket dependency was not
# reconsidered. Restored as a downstream adaptation: DinD stays, this runs
# alongside it. Some hosts expose the socket world-writable, which is why the
# gap went unnoticed.
#
# Idempotent and best-effort: if the socket is not mounted, or the chmod
# fails, the orchestrator still starts and worker-scale surfaces a clearer
# error later.
HOST_DOCKER_SOCK="${HOST_DOCKER_SOCK:-/var/run/docker-host.sock}"
if [ -S "$HOST_DOCKER_SOCK" ]; then
    if sudo /usr/bin/chmod 666 "$HOST_DOCKER_SOCK" 2>/dev/null; then
        log "Fixed host docker socket permissions ($HOST_DOCKER_SOCK)"
    else
        log "WARNING: could not chmod $HOST_DOCKER_SOCK — worker-scale may fail with EACCES"
    fi
else
    log "WARNING: host docker socket not mounted at $HOST_DOCKER_SOCK — worker-scale will not work"
fi

# Source wizard-delivered credentials persisted by a prior bootstrap
# (written by control-plane's bootstrap-complete handler — see
# generacy-ai/generacy#589). On restarts of an already-bootstrapped
# cluster, GH_TOKEN lives only in this file; without it, setup-credentials
# warns and the later `git fetch` in resolve-workspace.sh fails auth.
# Mirrors the same sourcing block in entrypoint-post-activation.sh.
WIZARD_CREDS="${WIZARD_CREDS_PATH:-/var/lib/generacy/wizard-credentials.env}"
if [ -f "$WIZARD_CREDS" ]; then
    log "Sourcing wizard credentials from $WIZARD_CREDS"
    set -a
    # shellcheck disable=SC1090
    source "$WIZARD_CREDS"
    set +a
fi

# Source non-secret app-config env vars from the persistent volume so that
# pre-daemon entrypoint steps and the orchestrator process inherit values like
# LIVEKIT_URL. Secrets are sourced later — see "Source app-config secrets"
# block after the control-plane socket-wait below.
NONSECRET_APP_ENV=/var/lib/generacy-app-config/env
if [ -f "$NONSECRET_APP_ENV" ]; then
    log "Sourcing app-config env from $NONSECRET_APP_ENV"
    set -a
    # shellcheck disable=SC1090
    source "$NONSECRET_APP_ENV"
    set +a
fi

# Configure git credentials
bash /usr/local/bin/setup-credentials.sh

# Keep the JIT git credential helper authoritative if VS Code (attached over a
# `code tunnel`) rewrites ~/.gitconfig back to a static, expiring token
# (generacy-ai/cluster-base#66). Backgrounded; self-exits outside wizard mode.
# Runs as node (this entrypoint's user) so it edits /home/node/.gitconfig.
bash /usr/local/bin/git-helper-guard.sh &

# Resolve workspace directory (handles devcontainer detection + clone)
source /usr/local/bin/resolve-workspace.sh

# Load cluster.yaml defaults (sets GENERACY_CHANNEL, WORKER_COUNT, WORKERS_ENABLED
# if not already provided via .env or environment)
source /usr/local/bin/load-cluster-config.sh

# Install generacy/agency packages into shared volume
SHARED_PACKAGES=/shared-packages
CHANNEL="${GENERACY_CHANNEL:-stable}"
MARKER_FILE="${SHARED_PACKAGES}/.installed-version"

install_packages() {
    # Seed a manifest in the shared volume declaring the core packages as
    # dependencies. /shared-packages has no package.json of its own, so without
    # this every already-installed package is *extraneous* to npm. The separate
    # best-effort cockpit install below then reconciles the tree on its own
    # terms and prunes everything it doesn't depend on — including the core
    # packages' bin symlinks (notably .bin/generacy). That leaves the final
    # `exec generacy orchestrator` failing with "generacy: not found" and the
    # orchestrator in a crash loop, but only on channels where the cockpit
    # package actually publishes (e.g. preview) so the second install succeeds
    # and reconciles. Declaring the core packages here keeps them in npm's ideal
    # tree so the cockpit install can no longer prune them
    # (generacy-ai/cluster-base#71). Keep this list in sync with the install
    # command below.
    log "Seeding ${SHARED_PACKAGES}/package.json to protect core packages from prune..."
    cat > "${SHARED_PACKAGES}/package.json" <<'EOF'
{
  "name": "generacy-shared-packages",
  "private": true,
  "dependencies": {
    "@generacy-ai/generacy": "*",
    "@generacy-ai/agency": "*",
    "@generacy-ai/agency-plugin-spec-kit": "*",
    "@generacy-ai/cluster-relay": "*",
    "@generacy-ai/control-plane": "*",
    "@generacy-ai/orchestrator": "*"
  }
}
EOF

    log "Installing @generacy-ai packages (channel: ${CHANNEL}) into ${SHARED_PACKAGES}..."
    npm install \
        --prefix "${SHARED_PACKAGES}" \
        --no-save \
        "@generacy-ai/generacy@${CHANNEL}" \
        "@generacy-ai/agency@${CHANNEL}" \
        "@generacy-ai/agency-plugin-spec-kit@${CHANNEL}" \
        "@generacy-ai/cluster-relay@${CHANNEL}" \
        "@generacy-ai/control-plane@${CHANNEL}" \
        "@generacy-ai/orchestrator@${CHANNEL}" \
        2>>"$SETUP_LOG" || { log "ERROR: npm install failed"; exit 1; }

    # Cockpit Claude Code plugin (generacy-ai/cluster-base#69). Installed as a
    # separate, best-effort step so it can NOT brick cluster boot: the package
    # may be absent from a given channel (e.g. before it is published to
    # ${CHANNEL}), and a missing tag would fail the whole install above. It lands
    # in the shared-packages volume where `generacy setup build` (G-S5) resolves
    # it (Tier 2) and copies commands/*.md into ~/.claude/commands/cockpit/,
    # making /cockpit:* available with no manual marketplace/npm steps.
    log "Installing @generacy-ai/claude-plugin-cockpit@${CHANNEL} (best-effort) into ${SHARED_PACKAGES}..."
    npm install \
        --prefix "${SHARED_PACKAGES}" \
        --no-save \
        "@generacy-ai/claude-plugin-cockpit@${CHANNEL}" \
        2>>"$SETUP_LOG" \
        || log "WARNING: cockpit plugin install failed (channel: ${CHANNEL}) — /cockpit:* may be unavailable (see $SETUP_LOG)"

    # Write marker: channel + installed version of generacy
    local version
    version=$(node -e "console.log(require('${SHARED_PACKAGES}/node_modules/@generacy-ai/generacy/package.json').version)" 2>/dev/null || echo "unknown")
    echo "${CHANNEL}:${version}" > "${MARKER_FILE}"
    log "Packages installed (version: ${version})"
}

SETUP_LOG="${SETUP_LOG:-/tmp/generacy-setup.log}"
if [ "${SKIP_PACKAGE_UPDATE:-false}" = "true" ]; then
    log "SKIP_PACKAGE_UPDATE=true — skipping npm install"
else
    install_packages
fi

# Add shared packages to PATH for this process
export PATH="${SHARED_PACKAGES}/node_modules/.bin:${PATH}"

# Register the cockpit MCP server for the orchestrator's Claude sessions at
# **user scope** (generacy-ai/cluster-base#75 — companion to generacy#917
# FR-010, whose MCP server shipped but is unreachable until something registers
# it). Contract source of truth:
# specs/917-improvement-spec-from-cockpit/contracts/entrypoint-registration.md.
#
# Runs HERE — after the shared-packages install + PATH export above — so the
# `generacy` binary the entry launches exists (it's symlinked into
# /usr/local/bin for every shell type, see #73, and resolves through the volume
# this install just populated). Writes ~/.claude.json's mcpServers.cockpit key
# directly (the documented user-scope location — equivalent to
# `claude mcp add --scope user cockpit -- generacy cockpit mcp`), which is
# deterministic and doesn't depend on the `claude` CLI's add/overwrite exit
# semantics.
#
# The WORKER entrypoint deliberately does NOT do this: not registering on
# workers is the primary isolation control; the GENERACY_CLUSTER_ROLE=worker
# refusal baked into `generacy cockpit mcp` is only defense-in-depth.
#
# Idempotent per the contract (#917 Q4-A — the entrypoint is the source of
# truth; upgrades must self-heal, and hand-edits in a rebuildable container
# aren't durable): a matching entry is a silent no-op; a stale/foreign entry is
# overwritten unconditionally, each with one log line to stderr. Best-effort —
# a failure warns but never bricks boot.
#
# Gated on the cockpit capability actually being installed
# (generacy-ai/cluster-base#78). On channels/points-in-time where the cockpit
# subcommand isn't published yet (e.g. stable before 2026-07-13), `generacy
# cockpit mcp` doesn't exist, so registering it unconditionally leaves a dead
# MCP server that errors "unknown command 'cockpit'" on EVERY Claude session
# start. Probe `generacy help cockpit` (commander's built-in help lookup: exit
# 0 iff the `cockpit` command is registered) rather than the issue's suggested
# `generacy cockpit --help` — the latter's `--help` short-circuits commander's
# unknown-command error and exits 0 even when cockpit is absent, so it can't
# distinguish present from absent. When the capability is ABSENT we don't
# register, and we also REMOVE any stale cockpit entry so a downgrade/rollback
# self-heals too. On a channel where cockpit IS installed, behavior is
# unchanged (entry registered/reconciled).
if generacy help cockpit >/dev/null 2>&1; then
    COCKPIT_CAPABLE=1
    log "cockpit capability present — reconciling cockpit MCP registration"
else
    COCKPIT_CAPABLE=0
    log "cockpit capability absent on channel ${CHANNEL} — ensuring no stale cockpit MCP entry remains"
fi

COCKPIT_CAPABLE="$COCKPIT_CAPABLE" node <<'NODE' || log "WARNING: cockpit MCP registration failed (see above) — /cockpit MCP tools may be unavailable in orchestrator sessions"
const fs = require('fs');
const os = require('os');
const path = require('path');

const configPath = path.join(os.homedir(), '.claude.json');
const DESIRED = { type: 'stdio', command: 'generacy', args: ['cockpit', 'mcp'] };
// Only register when the cockpit CLI is actually installed on this channel
// (generacy-ai/cluster-base#78). When absent, remove any stale entry rather
// than write/leave a dead one.
const capable = process.env.COCKPIT_CAPABLE === '1';

let raw;
try {
  raw = fs.readFileSync(configPath, 'utf8');
} catch (e) {
  if (e.code === 'ENOENT') {
    // No config file yet. If cockpit isn't installed there's nothing to
    // register and nothing to remove — a clean no-op.
    if (!capable) process.exit(0);
    raw = '{}';
  } else {
    console.error('[entrypoint] ERROR reading ' + configPath + ': ' + e.message);
    process.exit(1);
  }
}

let config;
try {
  config = raw.trim() ? JSON.parse(raw) : {};
} catch (e) {
  // Never clobber an unparseable config we might be racing with — bail loudly.
  console.error('[entrypoint] ERROR: ' + configPath + ' is not valid JSON; leaving it untouched (' + e.message + ')');
  process.exit(1);
}

if (!config.mcpServers || typeof config.mcpServers !== 'object') {
  config.mcpServers = {};
}

const existing = config.mcpServers.cockpit;

// Capability absent: `generacy cockpit mcp` can't start on this channel, so a
// registered entry would be dead and error on every session. Remove any stale
// entry (self-heals a downgrade/rollback) and never write a new one.
if (!capable) {
  if (!existing) process.exit(0); // Nothing registered — clean no-op.
  delete config.mcpServers.cockpit;
  // In-place write (O_TRUNC): ~/.claude.json is bind-mounted, so a rename-over
  // would break the mount. writeFileSync overwrites the same inode.
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.error('[entrypoint] removed stale cockpit MCP entry (cockpit CLI not installed on this channel)');
  process.exit(0);
}

// Capability present: reconcile toward DESIRED (existing self-heal semantics).
// Compare only command + args per the contract (ignore extra fields like an
// existing `type`), so a CLI-written-but-equivalent entry is left untouched.
const argsMatch = existing
  && Array.isArray(existing.args)
  && existing.args.length === DESIRED.args.length
  && existing.args.every((a, i) => a === DESIRED.args[i]);
const isCurrent = existing && existing.command === DESIRED.command && argsMatch;

if (isCurrent) {
  process.exit(0); // Already correct — no-op, do not log.
}

const hadEntry = !!existing;
let priorDesc = '';
if (hadEntry) {
  const parts = [];
  if (typeof existing.command === 'string') parts.push(existing.command);
  if (Array.isArray(existing.args)) parts.push(...existing.args.map(String));
  priorDesc = parts.join(' ') || JSON.stringify(existing);
}

config.mcpServers.cockpit = DESIRED;
// In-place write (O_TRUNC): ~/.claude.json is bind-mounted, so a rename-over
// would break the mount. writeFileSync overwrites the same inode.
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

if (hadEntry) {
  console.error('[entrypoint] reconciled cockpit MCP entry: prior command "' + priorDesc + '", now "generacy cockpit mcp"');
} else {
  console.error('[entrypoint] registered cockpit MCP server (user scope)');
}
NODE

# Run generacy setup if CLI is available.
# In wizard mode the workspace isn't cloned yet (credentials arrive post-activation),
# so workspace/build steps are deferred to entrypoint-post-activation.sh.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" = "wizard" ]; then
    log "Wizard mode — skipping pre-activation generacy setup; will run after activation"
elif command -v generacy >/dev/null 2>&1; then
    SETUP_LOG="/tmp/generacy-setup.log"
    log "Running generacy setup..."

    # Non-critical: log errors but continue
    generacy setup auth 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup auth' failed (see $SETUP_LOG)"

    # Important: log errors but continue (workspace needed for build)
    # Pass --config when config file exists to avoid ambiguity with multiple repos
    CONFIG_PATH="${WORKSPACE_DIR}/.generacy/config.yaml"
    if [ -f "$CONFIG_PATH" ]; then
        generacy setup workspace --config "$CONFIG_PATH" --clean 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup workspace' failed (see $SETUP_LOG)"
    else
        generacy setup workspace --clean 2>>"$SETUP_LOG" || log "WARNING: 'generacy setup workspace' failed (see $SETUP_LOG)"
    fi

    # Critical: trigger speckit recovery on failure
    generacy setup build 2>>"$SETUP_LOG" || {
        log "ERROR: 'generacy setup build' failed — attempting speckit recovery (see $SETUP_LOG)"
        bash /usr/local/bin/setup-speckit.sh 2>>"$SETUP_LOG" || log "ERROR: speckit recovery also failed (see $SETUP_LOG)"
    }
fi

# Light check: warn if speckit is missing (orchestrator can still run).
# Skip in wizard mode — speckit lives in the not-yet-cloned workspace.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" != "wizard" ] && [ -x "/usr/local/bin/setup-speckit.sh" ]; then
    if ! bash /usr/local/bin/setup-speckit.sh --verify 2>/dev/null; then
        log "WARNING: Speckit commands not available. Workers may fail to process phases."
    fi
fi

# Wizard mode: arm the post-activation hook.
# Spawns a background watcher that fires entrypoint-post-activation.sh when
# the bootstrap-complete sentinel appears. The trigger contract is documented
# in post-activation-watcher.sh — control-plane (generacy-cloud#532) creates
# the sentinel after persisting wizard-delivered credentials.
if [ "${GENERACY_BOOTSTRAP_MODE:-devcontainer}" = "wizard" ]; then
    POST_ACTIVATION_TRIGGER="${POST_ACTIVATION_TRIGGER:-/tmp/generacy-bootstrap-complete}"
    log "Arming post-activation watcher (trigger: ${POST_ACTIVATION_TRIGGER})"
    POST_ACTIVATION_TRIGGER="${POST_ACTIVATION_TRIGGER}" \
        bash /usr/local/bin/post-activation-watcher.sh &
fi

# Wait for Redis to be ready
log "Waiting for Redis at ${REDIS_HOST:-redis}:6379..."
while ! nc -z "${REDIS_HOST:-redis}" 6379 2>/dev/null; do
    sleep 1
done
log "Redis is ready"

# Start the in-cluster control-plane daemon. It owns the unix socket the
# orchestrator's StatusReporter writes to AND serves the /control-plane/*
# routes that the cloud relay forwards (e.g. PUT /control-plane/credentials/:id
# during the bootstrap wizard's "Install GitHub App" step).

# Shared internal-API key so the control-plane process can POST events back
# to the orchestrator's /internal/relay-events endpoint, which then forwards
# them through the cluster-relay client. See generacy-ai/generacy#594.
# Generated per-boot — never persisted, never leaves the container.
export ORCHESTRATOR_INTERNAL_API_KEY="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

CONTROL_PLANE_SOCKET_PATH="${CONTROL_PLANE_SOCKET_PATH:-/run/generacy-control-plane/control.sock}"
export CONTROL_PLANE_SOCKET_PATH
CONTROL_PLANE_LOG="${CONTROL_PLANE_LOG:-/tmp/control-plane.log}"

if [ -x "${SHARED_PACKAGES}/node_modules/.bin/control-plane" ]; then
    log "Starting control-plane daemon (socket: ${CONTROL_PLANE_SOCKET_PATH}, log: ${CONTROL_PLANE_LOG})"
    "${SHARED_PACKAGES}/node_modules/.bin/control-plane" >>"${CONTROL_PLANE_LOG}" 2>&1 &

    # Wait for the socket so the orchestrator's first StatusReporter push lands
    # cleanly. Bounded so a wedged daemon doesn't block startup forever — if
    # the socket never appears we log and continue; StatusReporter will retry.
    for _ in $(seq 1 50); do
        [ -S "${CONTROL_PLANE_SOCKET_PATH}" ] && break
        sleep 0.2
    done
    if [ -S "${CONTROL_PLANE_SOCKET_PATH}" ]; then
        log "Control-plane socket ready"
    else
        log "WARNING: control-plane socket not ready after 10s (see ${CONTROL_PLANE_LOG})"
    fi
else
    log "WARNING: control-plane binary not found in ${SHARED_PACKAGES}/node_modules/.bin/ — relay-forwarded /control-plane/* requests will 404"
fi

# Start the git-token proxy (generacy-ai/cluster-base#61). Workers have no local
# control-plane, so they cannot reach the JIT git credential helper's control
# socket directly. This proxy listens on a socket placed on a volume shared with
# the workers and forwards ONLY POST /git-token to the real control socket —
# giving workers the "mint a git token" capability without exposing the rest of
# the control-plane API. It runs only on the orchestrator (the sole holder of
# the control socket + cluster API key). The proxy itself ships in
# @generacy-ai/control-plane (generacy-ai/generacy#768) — co-located with the
# git-credential-generacy helper it serves — so cluster-base only launches it
# from the shared-packages install; the logic is typed, tested, and versioned
# with the control-plane /git-token route it forwards.
GIT_TOKEN_PROXY_SOCKET="${GIT_TOKEN_PROXY_SOCKET:-/run/generacy-git-token/control.sock}"
export GIT_TOKEN_PROXY_SOCKET
GIT_TOKEN_PROXY_LOG="${GIT_TOKEN_PROXY_LOG:-/tmp/git-token-proxy.log}"
GIT_TOKEN_PROXY_JS="${GIT_TOKEN_PROXY_JS:-${SHARED_PACKAGES}/node_modules/@generacy-ai/control-plane/dist/bin/git-token-proxy.js}"
if [ -f "${GIT_TOKEN_PROXY_JS}" ]; then
    log "Starting git-token proxy (socket: ${GIT_TOKEN_PROXY_SOCKET}, log: ${GIT_TOKEN_PROXY_LOG})"
    GIT_TOKEN_PROXY_SOCKET="${GIT_TOKEN_PROXY_SOCKET}" \
        CONTROL_PLANE_SOCKET_PATH="${CONTROL_PLANE_SOCKET_PATH}" \
        node "${GIT_TOKEN_PROXY_JS}" >>"${GIT_TOKEN_PROXY_LOG}" 2>&1 &
    for _ in $(seq 1 50); do
        [ -S "${GIT_TOKEN_PROXY_SOCKET}" ] && break
        sleep 0.2
    done
    if [ -S "${GIT_TOKEN_PROXY_SOCKET}" ]; then
        log "git-token proxy socket ready"
    else
        log "WARNING: git-token proxy socket not ready after 10s (see ${GIT_TOKEN_PROXY_LOG}) — worker git auth will fail until it comes up"
    fi
else
    log "WARNING: git-token proxy not found at ${GIT_TOKEN_PROXY_JS} (from @generacy-ai/control-plane) — worker git operations will not be able to fetch JIT tokens"
fi

# Source app-config secrets — must happen AFTER the control-plane daemon binds
# its socket because the daemon is what renders /run/generacy-app-config/secrets.env
# from the encrypted ClusterLocalBackend (see generacy-ai/generacy#632). The
# tmpfs is empty at container start; if this sourcing ran with the non-secret
# block earlier in the script the file wouldn't exist yet and the `exec generacy
# orchestrator` below would launch without secrets in its environment.
SECRET_APP_ENV=/run/generacy-app-config/secrets.env
if [ -f "$SECRET_APP_ENV" ]; then
    log "Sourcing app-config secrets from $SECRET_APP_ENV"
    set -a
    # shellcheck disable=SC1090
    source "$SECRET_APP_ENV"
    set +a
fi

# Ensure the orchestrator process runs with its CWD inside the user's repo.
# `process.cwd()` is what orchestrator-side file resolution falls back to —
# /files?path=… (files.ts) and readClusterYaml (relay-bridge.ts) both
# resolve workspace-relative paths against it. Without this cd, CWD stays
# at the Dockerfile's WORKDIR (/workspaces) and every workspace-relative
# read lands one level too high (e.g. /workspaces/.generacy/cluster.yaml
# instead of /workspaces/<repo>/.generacy/cluster.yaml), which the cloud UI
# surfaces as "Configuration Not Found".
if [ -n "${WORKSPACE_DIR:-}" ] && [ -d "$WORKSPACE_DIR" ]; then
    log "Changing CWD to workspace: $WORKSPACE_DIR"
    cd "$WORKSPACE_DIR"
else
    log "WARNING: WORKSPACE_DIR not set or missing; orchestrator CWD will be $(pwd) — workspace-relative file reads will fail"
fi

# Start orchestrator as PID 1
log "Starting orchestrator on port ${ORCHESTRATOR_PORT:-3100}..."
exec generacy orchestrator \
    --port "${ORCHESTRATOR_PORT:-3100}" \
    --redis-url "${REDIS_URL:-redis://redis:6379}" \
    ${LABEL_MONITOR_ENABLED:+--label-monitor}
