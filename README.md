# cluster-microservices

Generacy cluster image with Docker-in-Docker for app stacks: orchestrator + workers, Claude Code preinstalled, plus the Docker CE engine and `docker compose` so projects can run their own `docker-compose.yml` inside the cluster. Built from [.devcontainer/generacy/Dockerfile](.devcontainer/generacy/Dockerfile) and published to GitHub Container Registry as `ghcr.io/generacy-ai/cluster-microservices`.

`cluster-microservices` is one of the cluster image variants consumed by `npx generacy launch`, and is the variant to pick when projects need to spin up their own service containers (databases, queues, sidecar apps). It tracks `cluster-base` upstream — the credentials/uid isolation model and entrypoints are inherited; only the DinD layer is added on top. Architecture context: see [tetrad-development/docs/dev-cluster-architecture.md](https://github.com/generacy-ai/tetrad-development/blob/develop/docs/dev-cluster-architecture.md) — "Cluster image variants".

## Publishing

The image is built and published by [.github/workflows/publish-cluster-image.yml](.github/workflows/publish-cluster-image.yml).

**Triggers:**
- **Tag push matching `v*`** — releases. Builds, publishes `:<tag>` and `:latest`, then runs the smoke-test job.
- **`workflow_dispatch`** — manual test publish from the Actions tab. Tags only `:<tag-input>` (does not move `:latest`).

**Build:**
- Uses Docker Buildx for multi-arch: `linux/amd64` and `linux/arm64`.
- GitHub Actions cache (`type=gha`) speeds up reruns.
- Stamps OCI labels: `org.opencontainers.image.source`, `.description`, `.licenses`, `.revision`, `.version`.

**Smoke test:** A separate `smoke-test` job pulls the freshly published image and runs two checks:

1. **Credhelper uid** — `docker run --rm <image> id credhelper` and asserts `uid=1002`. Guards the v1.5 phase-2 isolation uids (see [Dockerfile](.devcontainer/generacy/Dockerfile) — `generacy-workflow` uid 1001 and `credhelper` uid 1002).
2. **DinD startup** — `docker run --privileged --rm -e ENABLE_DIND=true <image> bash -lc "/usr/local/bin/setup-docker-dind.sh && docker info"`. Confirms the in-container Docker daemon starts and answers, which is the variant's whole reason for existing.

## Tag scheme

| Tag                                                       | When applied             | Floats? |
| --------------------------------------------------------- | ------------------------ | ------- |
| `ghcr.io/generacy-ai/cluster-microservices:vX.Y.Z`        | Tag push `vX.Y.Z`        | No      |
| `ghcr.io/generacy-ai/cluster-microservices:latest`        | Tag push (any `v*`)      | Yes     |
| `ghcr.io/generacy-ai/cluster-microservices:<dispatch-tag>`| `workflow_dispatch` only | No      |

Consumers (the `generacy` CLI) pull a pinned semver tag for releases; `latest` is provided for ad-hoc local pulls and is not the recommended production target.

## Cutting a release

1. Merge release-ready changes to `develop` (or your release branch).
2. Tag and push:

   ```bash
   git tag v1.5.0
   git push origin v1.5.0
   ```

3. Watch the workflow at <https://github.com/generacy-ai/cluster-microservices/actions/workflows/publish-cluster-image.yml>.
4. After it succeeds, verify a public pull works (see below).

## Making the package public (one-time, after first publish)

GHCR packages default to **private**, even when published from a public repo. After the first successful publish, an org admin must mark the package public so unauthenticated `docker pull` works:

1. Go to <https://github.com/orgs/generacy-ai/packages/container/cluster-microservices/settings>.
2. Scroll to **Danger Zone → Change package visibility**.
3. Select **Public** and confirm.
4. Optional but recommended: under **Manage Actions access**, ensure the `cluster-microservices` repo has `Write` so this workflow can keep publishing.

Verify from any unauthenticated machine:

```bash
docker logout ghcr.io
docker pull ghcr.io/generacy-ai/cluster-microservices:latest
```

This step is only needed once per package name. Subsequent tags inherit the public visibility.

## Manual test publish

Use this when validating workflow changes without cutting a real release:

1. Open the **Actions** tab → **Publish cluster-microservices image** → **Run workflow**.
2. Pick a branch and supply a tag (e.g. `dev-pr42`).
3. The workflow publishes `ghcr.io/generacy-ai/cluster-microservices:dev-pr42` and runs the smoke tests. `:latest` is **not** moved.
