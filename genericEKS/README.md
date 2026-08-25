# Neo4j Hybrid GDS Cluster on AWS EKS

A reference deployment of a **Neo4j Enterprise hybrid cluster** on EKS:

- 3 core **PRIMARY** members
- 2 secondary **GDS** (Graph Data Science) members
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
# classes, Neo4j installs, and load balancers. Also the default with no
# arguments -- runs to completion with no prompts.
./scripts/startall.sh --all

# Or just the k8s/AWS infrastructure, without installing Neo4j:
./scripts/startall.sh --k8s
```

At the end, `startall.sh` prints the Bolt/Browser URLs for the core LB and
each GDS LB, plus the login credentials. Once every pod shows `1/1
Running`, replicate the database out to the GDS secondaries by running this
against the core LB (or a core pod):

```cypher
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
