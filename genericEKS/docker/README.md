# Custom Neo4j images (optional, not used by default)

`startall.sh` uses the official multi-arch Neo4j Enterprise image by default
(see the root [README.md](../README.md) and [CLAUDE.md](../CLAUDE.md)). The
Dockerfiles here are for building a **custom** image instead — rudimentary,
debug-oriented, not required for the normal deploy path.

- **`axb-debug/`** — for core (PRIMARY) members. No GDS installed.
- **`axbg-debug/`** — for secondary GDS members. Same as `axb-debug` plus the
  GDS plugin. You can remove the extra package installs (`zip unzip awscli
  curl wget sysstat python3 vim-tiny nfs-common`) for a production image —
  they're only here for interactive debugging inside the container.

Both are based on `neo4j:5.14.0-enterprise` and install the Bloom plugin and
the APOC Extended jar via `wget` at build time (network access required
during `docker build`).

## Building

This is an ARM64 build (matches the `m7g`/`r7g`/`r6g` Graviton nodegroups
used elsewhere in this repo) — drop `--platform linux/arm64` for AMD64:

```bash
docker buildx build --platform linux/arm64 \
  -t <account-id>.dkr.ecr.us-east-2.amazonaws.com/<your-repo>:neo4j-<tag>-enterprise-arm \
  --push axbg-debug/.
```

Push to an ECR repo **in the same AWS account as your EKS cluster** — a
repo in a different account needs cross-account pull access set up first, or
every pod 403s on `ImagePullBackOff`.

## Using a custom image

Set `image.customImage` in `hybrid-core-small.yaml`/`hybrid-gds-small.yaml`
to the pushed image URI (both files have this commented out by default,
pointing at an example from a different AWS account — don't uncomment that
example ARN as-is). See the "Images" bullet in [CLAUDE.md](../CLAUDE.md) for
the tradeoffs (no GDS baked into the official image vs. baking it into a
custom one here).
