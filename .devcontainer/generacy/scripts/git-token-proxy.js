#!/usr/bin/env node
// git-token-proxy — minimal, single-route forwarder for the JIT git credential
// helper (generacy-ai/cluster-base#61).
//
// Why this exists: the JIT git credential helper (`git-credential-generacy`,
// shipped in @generacy-ai/control-plane) obtains a fresh GitHub installation
// token per git op by POSTing to the in-cluster control-plane's Unix socket
// (generacy-ai/generacy#766). But the control-plane daemon runs ONLY in the
// orchestrator and binds ONLY a per-container socket — worker containers have
// their own empty /run/generacy-control-plane tmpfs and cannot reach it.
//
// Rather than share the orchestrator's full control socket with workers (which
// would expose every control-plane route — credential writes, lifecycle
// actions — to worker containers and to the uid-1001 agent-workflow processes
// that share the `node` group), this proxy runs on the orchestrator, listens
// on a socket placed on a volume shared with the workers, and forwards ONLY
// `POST /git-token` to the real control socket. Workers thus gain exactly one
// capability — "mint me a git token" — and nothing else.
//
// Config (env):
//   GIT_TOKEN_PROXY_SOCKET   listen socket (shared volume)  default /run/generacy-git-token/control.sock
//   CONTROL_PLANE_SOCKET_PATH upstream control socket        default /run/generacy-control-plane/control.sock

// CommonJS (require, not import): this is a standalone .js file with no
// accompanying package.json, so Node loads it as CommonJS by default.
const http = require('node:http');
const fs = require('node:fs');

const LISTEN_SOCKET =
    process.env['GIT_TOKEN_PROXY_SOCKET'] ?? '/run/generacy-git-token/control.sock';
const UPSTREAM_SOCKET =
    process.env['CONTROL_PLANE_SOCKET_PATH'] ?? '/run/generacy-control-plane/control.sock';

function log(msg) {
    const ts = new Date().toISOString();
    process.stdout.write(`[${ts}] [git-token-proxy] ${msg}\n`);
}

function sendJson(res, status, body) {
    const payload = JSON.stringify(body);
    res.writeHead(status, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
    });
    res.end(payload);
}

const server = http.createServer((req, res) => {
    // Single allowed route: everything else is refused so this proxy can never
    // be used as a general control-plane back door.
    if (req.method !== 'POST' || req.url !== '/git-token') {
        sendJson(res, 404, {
            code: 'NOT_FOUND',
            error: 'git-token-proxy only forwards POST /git-token',
        });
        // Drain the request so the socket frees cleanly.
        req.resume();
        return;
    }

    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('error', () => {
        // Client went away mid-request — nothing to forward.
    });
    req.on('end', () => {
        const body = Buffer.concat(chunks);
        const upstream = http.request(
            {
                socketPath: UPSTREAM_SOCKET,
                path: '/git-token',
                method: 'POST',
                headers: {
                    'content-type': 'application/json',
                    'content-length': body.length,
                },
            },
            (upRes) => {
                res.writeHead(upRes.statusCode ?? 502, {
                    'content-type': upRes.headers['content-type'] ?? 'application/json',
                });
                upRes.pipe(res);
            },
        );
        upstream.on('error', (err) => {
            // Upstream (control-plane) unreachable — surface a clear error the
            // credential helper turns into CONTROL_SOCKET_UNREACHABLE, never a
            // silent fallback to a stale token.
            const cause = err.code ?? err.message;
            sendJson(res, 502, {
                code: 'CONTROL_SOCKET_UNREACHABLE',
                error: `control-plane socket at ${UPSTREAM_SOCKET} unreachable (${cause})`,
            });
        });
        upstream.write(body);
        upstream.end();
    });
});

// Remove any stale socket left on the shared volume by a prior boot (the volume
// persists across container restarts; the socket file does not survive a dead
// listener).
try {
    fs.unlinkSync(LISTEN_SOCKET);
} catch {
    // ENOENT is fine.
}

server.on('error', (err) => {
    log(`FATAL: listen error: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
});

server.listen(LISTEN_SOCKET, () => {
    // 0660 so the orchestrator (uid 1000) and worker-side git processes that
    // share the `node` group (incl. uid-1001 agent workflows) can connect,
    // while other/world cannot.
    try {
        fs.chmodSync(LISTEN_SOCKET, 0o660);
    } catch {
        // Best-effort.
    }
    log(`Listening on ${LISTEN_SOCKET} → forwarding POST /git-token to ${UPSTREAM_SOCKET}`);
});

function shutdown() {
    server.close(() => {
        try {
            fs.unlinkSync(LISTEN_SOCKET);
        } catch {
            // Ignore.
        }
        process.exit(0);
    });
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
