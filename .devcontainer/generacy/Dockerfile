# Generacy Development Cluster
# Multi-stage build for efficient layer caching
#
# Customize this Dockerfile for your project's needs.
# The stages are structured so that infrequently-changing layers
# (system packages, CLIs) are cached separately from the tooling layer.

# -- Stage 1: System dependencies (rarely changes, caches well) ---------------
FROM mcr.microsoft.com/devcontainers/typescript-node:22-bookworm AS base

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg netcat-openbsd redis-tools \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# -- Stage 2: Generacy tooling (changes with npm versions) --------------------
FROM base AS tooling

# Install Claude Code
USER node
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# Add Claude to system-wide PATH
ENV PATH="/home/node/.local/bin:${PATH}"

# Install code-server (pinned). Standalone install prefix puts the binary at
# /usr/local/bin/code-server, which the in-cluster control-plane lifecycle
# endpoint expects (CODE_SERVER_BIN default).
ARG CODE_SERVER_VERSION=4.96.4
ENV CODE_SERVER_VERSION=${CODE_SERVER_VERSION}
RUN curl -fsSL https://code-server.dev/install.sh \
        | sh -s -- --method standalone --prefix /usr/local --version "${CODE_SERVER_VERSION}" \
 && code-server --version

# Install Microsoft VS Code CLI (`code`) — distinct from code-server above.
# Needed by control-plane's vscode-tunnel-start lifecycle action to register
# a VS Code Tunnel for the cluster (so VS Code Desktop deep-links land in
# the container, not the user's host machine). Pin the version — stdout-format
# drift from Microsoft would break the device-code regex parsing.
ARG VSCODE_CLI_VERSION=1.95.3
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
         amd64) VSCODE_ARCH=cli-linux-x64 ;; \
         arm64) VSCODE_ARCH=cli-linux-arm64 ;; \
         *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL "https://update.code.visualstudio.com/${VSCODE_CLI_VERSION}/${VSCODE_ARCH}/stable" -o /tmp/code.tar.gz \
    && tar -xzf /tmp/code.tar.gz -C /usr/local/bin code \
    && rm /tmp/code.tar.gz \
    && code --version

# Pre-install the curated extension set so first IDE launch is fast.
# The list lives in a controlled file and is read line-by-line; install runs
# as the node user since extensions are scoped to that user's data dir.
COPY code-server-extensions.txt /usr/local/share/code-server-extensions.txt
USER node
RUN set -eu; \
    grep -vE '^\s*(#|$)' /usr/local/share/code-server-extensions.txt \
        | while IFS= read -r ext; do \
            [ -z "$ext" ] && continue; \
            code-server --install-extension "$ext" --force; \
          done
USER root

# -- Stage 3: Docker-in-Docker (CLI + daemon + compose) -----------------------
FROM tooling AS dind

# Install Docker CE for standalone DinD (docker compose up without VS Code features)
USER root
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        | tee /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin iptables \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Let node user start dockerd via sudo (for DinD in standalone mode)
RUN usermod -aG docker node \
    && echo "node ALL=(root) NOPASSWD: /usr/bin/dockerd" > /etc/sudoers.d/docker-node \
    && chmod 0440 /etc/sudoers.d/docker-node

# -- Stage 4: Final image -----------------------------------------------------
FROM dind AS final

# Copy entrypoint scripts
COPY --chmod=755 scripts/ /usr/local/bin/

# Create workspaces directory with node ownership
RUN mkdir -p /workspaces && chown -R node:node /workspaces

# Pre-create shared-packages mount point with node ownership
# (Docker named volumes default to root, causing EACCES for node user)
RUN mkdir -p /shared-packages && chown node:node /shared-packages

# Credentials architecture: workflow subprocess isolation (v1.5)
# See tetrad-development docs/credentials-architecture-plan.md decision #4.
# These uids exist specifically to enforce uid-boundary isolation between the
# orchestrator/node user, the agent workflow process, and the credhelper daemon
# inside a single worker container. Do NOT consolidate them away — the
# isolation model relies on three distinct uids inside the same container.
# DinD note: only the `node` uid (1000) is in the `docker` group. The workflow
# uid (1001) and credhelper uid (1002) deliberately do NOT have docker access —
# the workflow uid will reach the in-container DinD daemon only through the
# scoped docker-socket-proxy that lands in phase 9 (architecture decision #13).
#   generacy-workflow (uid 1001): agent processes run as this user during workflows
#   credhelper        (uid 1002): in-worker credhelper daemon runs as this user
RUN useradd --uid 1001 --gid node --no-create-home --shell /bin/bash generacy-workflow \
 && useradd --uid 1002 --gid node --no-create-home --shell /usr/sbin/nologin credhelper

# Credhelper binary + plugins drop here in a future image build.
# Root-owned, world-readable (0755) so the credhelper uid can read/exec, but
# only root can modify the contents at runtime.
RUN mkdir -p /usr/local/lib/generacy-credhelper \
 && chown root:root /usr/local/lib/generacy-credhelper \
 && chmod 0755 /usr/local/lib/generacy-credhelper

# Pre-create the credentials state dir so the named-volume mount inherits
# ownership/mode on first-init. Owned by uid 1000 (node), mode 0700 — see
# .devcontainer/generacy/docker-compose.yml worker service.
RUN mkdir -p /var/lib/generacy \
 && chown node:node /var/lib/generacy \
 && chmod 0700 /var/lib/generacy

# Pre-create the app-config state dir so the named-volume mount inherits
# ownership/mode on first-init. Owned by uid 1000 (node), mode 0750. Holds
# the materialized non-secret env file and metadata YAML written by the
# control-plane daemon (which runs as the node uid in the orchestrator
# container). Without this pre-create, the daemon crashes on init with
# EACCES because /var/lib is root-owned and the node uid can't create the
# subdirectory itself. See .devcontainer/generacy/docker-compose.yml
# orchestrator service.
RUN mkdir -p /var/lib/generacy-app-config \
 && chown node:node /var/lib/generacy-app-config \
 && chmod 0750 /var/lib/generacy-app-config

# Pre-create the VS Code CLI state dir so the named-volume mount inherits node
# ownership on first-init. `code` 1.95.3 writes tunnel auth state (token.json,
# tunnel-stable.lock) to /home/node/.vscode/cli/. Without this pre-create,
# Docker would create the mount point as root-owned and `code` (running as
# node) couldn't write to it. See .devcontainer/generacy/docker-compose.yml
# orchestrator service.
RUN mkdir -p /home/node/.vscode/cli \
 && chown -R node:node /home/node/.vscode

# +============================================================================+
# |  Customize below: add your project's system dependencies                    |
# |                                                                             |
# |  Examples:                                                                  |
# |    RUN apt-get update && apt-get install -y python3 python3-pip             |
# |    RUN apt-get update && apt-get install -y postgresql-client               |
# |    RUN npm install -g pnpm@9                                                |
# +============================================================================+

USER node
WORKDIR /workspaces
