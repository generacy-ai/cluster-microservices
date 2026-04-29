# cluster-base

Minimal Generacy cluster image: orchestrator + workers, Claude Code preinstalled, no extra services. Built from [.devcontainer/generacy/Dockerfile](.devcontainer/generacy/Dockerfile) and published to GitHub Container Registry as `ghcr.io/generacy-ai/cluster-base`.

`cluster-base` is one of the cluster image variants consumed by `npx generacy launch`. Architecture context: see [tetrad-development/docs/dev-cluster-architecture.md](https://github.com/generacy-ai/tetrad-development/blob/develop/docs/dev-cluster-architecture.md) — "Cluster image variants".

## Publishing

The image is built and published by [.github/workflows/publish-cluster-image.yml](.github/workflows/publish-cluster-image.yml).

**Triggers:**
- **Tag push matching `v*`** — releases. Builds, publishes `:<tag>` and `:latest`, then runs the smoke-test job.
- **`workflow_dispatch`** — manual test publish from the Actions tab. Tags only `:<tag-input>` (does not move `:latest`).

**Build:**
- Uses Docker Buildx for multi-arch: `linux/amd64` and `linux/arm64`.
- GitHub Actions cache (`type=gha`) speeds up reruns.
- Stamps OCI labels: `org.opencontainers.image.source`, `.description`, `.licenses`, `.revision`, `.version`.

**Smoke test:** A separate `smoke-test` job pulls the freshly published image and runs `docker run --rm <image> id credhelper`, asserting `uid=1002`. This guards the v1.5 phase-2 isolation uids (see [Dockerfile](.devcontainer/generacy/Dockerfile) — `generacy-workflow` uid 1001 and `credhelper` uid 1002).

## Tag scheme

| Tag                                              | When applied                  | Floats? |
| ------------------------------------------------ | ----------------------------- | ------- |
| `ghcr.io/generacy-ai/cluster-base:vX.Y.Z`        | Tag push `vX.Y.Z`             | No      |
| `ghcr.io/generacy-ai/cluster-base:latest`        | Tag push (any `v*`)           | Yes     |
| `ghcr.io/generacy-ai/cluster-base:<dispatch-tag>`| `workflow_dispatch` only      | No      |

Consumers (the `generacy` CLI) pull a pinned semver tag for releases; `latest` is provided for ad-hoc local pulls and is not the recommended production target.

## Cutting a release

1. Merge release-ready changes to `develop` (or your release branch).
2. Tag and push:

   ```bash
   git tag v1.5.0
   git push origin v1.5.0
   ```

3. Watch the workflow at <https://github.com/generacy-ai/cluster-base/actions/workflows/publish-cluster-image.yml>.
4. After it succeeds, verify a public pull works (see below).

## Making the package public (one-time, after first publish)

GHCR packages default to **private**, even when published from a public repo. After the first successful publish, an org admin must mark the package public so unauthenticated `docker pull` works:

1. Go to <https://github.com/orgs/generacy-ai/packages/container/cluster-base/settings>.
2. Scroll to **Danger Zone → Change package visibility**.
3. Select **Public** and confirm.
4. Optional but recommended: under **Manage Actions access**, ensure the `cluster-base` repo has `Write` so this workflow can keep publishing.

Verify from any unauthenticated machine:

```bash
docker logout ghcr.io
docker pull ghcr.io/generacy-ai/cluster-base:latest
```

This step is only needed once per package name. Subsequent tags inherit the public visibility.

## Manual test publish

Use this when validating workflow changes without cutting a real release:

1. Open the **Actions** tab → **Publish cluster-base image** → **Run workflow**.
2. Pick a branch and supply a tag (e.g. `dev-pr42`).
3. The workflow publishes `ghcr.io/generacy-ai/cluster-base:dev-pr42` and runs the smoke test. `:latest` is **not** moved.
