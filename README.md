# cluster-microservices

Generacy cluster image with Docker-in-Docker for app stacks: orchestrator + workers, Claude Code preinstalled, plus the Docker CE engine and `docker compose` so projects can run their own `docker-compose.yml` inside the cluster. Built from [.devcontainer/generacy/Dockerfile](.devcontainer/generacy/Dockerfile) and published to GitHub Container Registry as `ghcr.io/generacy-ai/cluster-microservices`.

`cluster-microservices` is one of the cluster image variants consumed by `npx generacy launch`, and is the variant to pick when projects need to spin up their own service containers (databases, queues, sidecar apps). It tracks `cluster-base` upstream — the credentials/uid isolation model and entrypoints are inherited; only the DinD layer is added on top. Architecture context: see [tetrad-development/docs/dev-cluster-architecture.md](https://github.com/generacy-ai/tetrad-development/blob/develop/docs/dev-cluster-architecture.md) — "Cluster image variants".

## Default vs. local build

The default [.devcontainer/generacy/docker-compose.yml](.devcontainer/generacy/docker-compose.yml) pulls the pre-built image from the registry. The `Dockerfile` is kept in the repo for the power-user path: comment the `image:` line and uncomment the `build:` block to build locally (e.g. when customizing the image).

## Publishing

This repo no longer publishes its own image. The build/publish workflow lives in [generacy-ai/generacy](https://github.com/generacy-ai/generacy) — it checks out cluster-microservices at the requested channel, builds the image, and pushes channel-aware tags.

The publish workflow was moved out of this repo so that derived project repos created from cluster-microservices do not inherit a `.github/workflows/` path. GitHub Apps require a separate `Workflows: write` permission to create trees containing workflow files; copying cluster-microservices into a user-owned repo via the GitHub App was failing on `git/trees` because of that permission gap.

## Channel and tag scheme

| Channel   | Branch    | Image tag                                                  |
| --------- | --------- | ---------------------------------------------------------- |
| `stable`  | `main`    | `ghcr.io/generacy-ai/cluster-microservices:stable`         |
| `preview` | `develop` | `ghcr.io/generacy-ai/cluster-microservices:preview`        |

The orchestrator and worker honor `GENERACY_CHANNEL` (default: `stable`). The `CHANNEL_BRANCH_MAP` in worker config is `stable→main, preview→develop`.

## Verifying a public pull

After the package is marked public (one-time per package, by an org admin at <https://github.com/orgs/generacy-ai/packages/container/cluster-microservices/settings>), unauthenticated pulls work:

```bash
docker logout ghcr.io
docker pull ghcr.io/generacy-ai/cluster-microservices:stable
```
