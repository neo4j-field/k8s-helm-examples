# Neo4j Hybrid GDS Cluster on AWS EKS

A reference deployment of a **Neo4j Enterprise hybrid cluster** on EKS:

- 3 core **PRIMARY** members
- 0-2 secondary **GDS** (Graph Data Science) members (opt-in: `startall.sh --gds-count {0,1,2}`, default `0`)
- 1 Network Load Balancer (NLB) fronting the core members
- 1 NLB per GDS member (GDS calls run over a non-routing Bolt connection, so
  each GDS secondary needs its own direct entry point rather than sharing
  the core LB)
- Load balancers are left running across `stopall.sh --uninstall-neo4j`
  runs, on purpose, so their IPs (and any attached ACM cert) survive a
  reinstall — this repo has no DNS, so a recreated LB with a new IP would
  break TLS

See [CLAUDE.md](CLAUDE.md) for the full set of design decisions and gotchas
(load balancer controller requirements, storage/EFS provisioning, cluster
topology, memory sizing, etc.) — this file covers the practical "how do I
run it" side.

## Naming

| Component | Name |
|---|---|
| EKS cluster | `jhair-cluster` |
| Nodegroup | `neo4j-ng` |
| Namespace | `neo4j-ns` |
| Core Helm releases | `neo4j-1`, `neo4j-2`, `neo4j-3` |
| GDS Helm releases | `neo4j-gds-1`, `neo4j-gds-2` |
| Core load balancer | `neo4j-core-lb` (manifest: `lb-neo4j-core.yaml`) |
| GDS load balancers | `neo4j-gds-1-lb`, `neo4j-gds-2-lb` (manifests: `lb1-gds.yaml`, `lb2-gds.yaml`) |

## Load balancer → Neo4j port mapping

Each NLB exposes two ports. TLS termination is currently **disabled** (no
ACM cert provisioned in this account/region — see `CLAUDE.md`), so the
`http` listener is plain, unencrypted port 80 rather than 443:

| LB listener port | Protocol | Forwards to (pod `targetPort`) | Purpose |
|---|---|---|---|
| `7687` | TCP | `7687` (Bolt) | Driver/Browser Bolt connections |
| `80` | TCP | `7474` (HTTP) | Neo4j Browser web UI |

To re-enable TLS termination: get a real ACM cert ARN in the same AWS
account/region as the cluster, change the `http` listener's `port: 80` back
to `443` in `lb-neo4j-core.yaml`/`lb1-gds.yaml`/`lb2-gds.yaml`, and uncomment
the `service.beta.kubernetes.io/aws-load-balancer-ssl-cert`/
`ssl-negotiation-policy` annotations in each file.

## Deploying

```bash
# Full deploy: cluster, nodegroup, namespace, secret/licenses, EFS, storage
# classes, Neo4j core installs, and the core load balancer. Also the
# default with no arguments -- runs to completion with no prompts. GDS is
# opt-in (see --gds-count below), so this alone is core-only.
./scripts/startall.sh --all

# Or just the k8s/AWS infrastructure, without installing Neo4j:
./scripts/startall.sh --k8s

# Add 1 or 2 GDS secondaries (and their load balancers) -- default is 0:
./scripts/startall.sh --gds-count 2

# Optionally override the EKS cluster name and/or the Helm release name
# prefix (defaults: jhair-cluster, neo4j):
./scripts/startall.sh --cluster-name my-cluster --release-name mydb
```

`startall.sh` writes any files it needs to generate for a deployment into
`deployed-<cluster>-<release>/` (gitignored) — one directory per
cluster+release combination, so multiple deployments can coexist without
overwriting each other's record. This includes `deployment.env`, which
records the cluster name, release prefix, and GDS count actually used.
`stopall.sh` finds these automatically:

```bash
# If exactly one deployed-*/ directory exists, stopall.sh uses it without
# any extra flags:
./scripts/stopall.sh --uninstall-neo4j

# If you've deployed more than one (different --cluster-name/--release-name),
# point stopall.sh at the right one the same way you deployed it:
./scripts/stopall.sh --all --cluster-name my-cluster --release-name mydb
```

If more than one `deployed-*/` directory matches, `stopall.sh` lists them
and asks you to disambiguate rather than guessing which cluster to tear
down. A good place to redirect log output too, e.g.
`./scripts/startall.sh --all | tee deployed-jhair-cluster-neo4j/startup.log`
(pick the directory name matching what you're deploying).

At the end, `startall.sh` prints the Bolt/Browser URLs for the core LB and
each GDS LB (if any), plus the login credentials. If you deployed GDS
secondaries, once every pod shows `1/1 Running`, replicate the database out
to them by running this against the core LB (or a core pod):

```cypher
-- SECONDARY count should match whatever --gds-count you deployed with
ALTER DATABASE neo4j SET TOPOLOGY 3 PRIMARY 2 SECONDARY
```

### Login

Username/password come from the `neo4jpwd` secret, set by the `NEO4J_AUTH`
variable in `scripts/startall.sh` (default `neo4j` / `Neo4j123`).

## Tearing down

`scripts/stopall.sh` takes independent, combinable options and does nothing
(just prints usage) if you run it with no arguments, since it's destructive:

```bash
# Uninstall Neo4j only (Helm releases + wipe their data/transactions PVs).
# Leaves load balancers, nodegroup, cluster, and EFS running.
./scripts/stopall.sh --uninstall-neo4j

# Also delete the load balancers:
./scripts/stopall.sh --uninstall-neo4j --undeploy-lb

# Full wipe: Neo4j + load balancers + nodegroup + EKS cluster + EFS.
# --all implies --uninstall-neo4j and --undeploy-lb, since skipping either
# would orphan still-billing AWS resources once the cluster is gone.
./scripts/stopall.sh --all
```

## Custom images (optional)

By default, the values files use the official multi-arch Neo4j Enterprise
image. If you need a custom image (e.g. with GDS baked in instead of
installed via plugin), see [`docker/README.md`](docker/README.md).

## Other files

`misc-examples/` holds root-level files kept for reference that aren't
read by `startall.sh`/`stopall.sh` at all: standalone helper scripts whose
logic those scripts now do inline, an alternate/legacy cluster config, a
single-member standalone deploy example, and a couple of older sample
files.

## Before running `scripts/startall.sh`

If this machine is also used against non-EKS clusters (e.g. AKS), your AWS SSO
session may be expired and/or `kubectl`'s current context may be pointed at a
different cluster. `scripts/startall.sh` checks/fixes both automatically,
but you can also do it manually first:

```bash
# 1. Refresh AWS SSO credentials (needed by eksctl)
aws sso login

# 2. Point kubectl at the EKS cluster (name/region come from eks_create_cluster-jhair.yaml)
aws eks update-kubeconfig --name jhair-cluster --region us-east-2

# 3. Confirm the right context is active
kubectl config get-contexts
```
