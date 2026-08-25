# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`genericEKS/` is one of three cloud examples (`genericEKS`, `genericAKS`, `genericGKE`) under the `k8s-helm-examples` repo. It holds reference material — **not an application** — for deploying **Neo4j Enterprise on AWS EKS via the official `neo4j/neo4j` Helm chart**. There is no build/lint/test cycle; work here means editing Helm values files, Kubernetes manifests, and shell wrappers, then applying them with `helm`, `kubectl`, and `eksctl` against a live cluster.

The headline example is a **hybrid GDS cluster**: 3 core PRIMARY members + 2 secondary GDS members, each fronted by its own AWS NLB that terminates TLS and passes TCP to Bolt. GDS members get individual load balancers because GDS calls run over a non-routing Bolt connection.

## Deployment lifecycle

`scripts/startall.sh` and `scripts/stopall.sh` are the canonical entry points and are idempotent end to end — everything (secret, license configmap, storage classes, EFS filesystem/mount targets/CSI driver, cluster, nodegroup, Neo4j installs, load balancers) is provisioned/torn down by the scripts themselves; there's no separate manual prerequisite step. `create_storageclass.sh` and `createPasswordSecret.sh`/`create-licenses-configmap.sh` still exist standalone (and `startall.sh` calls `create_storageclass.sh` itself), but running the full scripts is the normal path.

`startall.sh` takes a mode argument (defaults to the full pipeline with no arguments); `stopall.sh` takes independent, combinable options and does nothing (just shows usage) with no arguments, since it's destructive:

```bash
# Bring up just the k8s/AWS infrastructure (cluster, nodegroup, namespace,
# secret/licenses, EFS, storage classes) without installing Neo4j:
scripts/startall.sh --k8s

# Full pipeline: k8s infrastructure + Neo4j installs + load balancers.
# Also what runs with no arguments at all.
scripts/startall.sh --all

# Tear down Neo4j only (helm uninstall + wipe data/transactions PVs):
scripts/stopall.sh --uninstall-neo4j

# Also delete the 3 load balancers:
scripts/stopall.sh --uninstall-neo4j --undeploy-lb

# Full wipe: Neo4j + load balancers + nodegroup + EKS cluster + EFS.
# --all implies --uninstall-neo4j and --undeploy-lb (skipping either would
# orphan still-billing AWS resources once the cluster is gone -- see
# scripts/stopall.sh's header comment).
scripts/stopall.sh --all
```

Single-member / standalone deploys use `helm upgrade -i <release> neo4j/neo4j -f <values>.yaml` directly.

## Key conventions

- **Services disabled in chart, load balancers external.** Every values file sets `services.neo4j.enabled: false`. LBs are standalone `Service` manifests (`lb-neo4j-core.yaml`, `lb1-gds.yaml`, `lb2-gds.yaml`, `standalone-lb.yaml`) so their IPs/ACM certs survive `helm uninstall` — this repo has no DNS, so a recreated LB with a new IP would break the TLS certs. Do **not** re-enable chart services to "simplify"; it defeats this design.
- **LBs require AWS Load Balancer Controller.** The `service.beta.kubernetes.io/aws-load-balancer-*` annotations (nlb, TCP backend, ACM cert ARN) are only reconciled into a real NLB if the AWS Load Balancer Controller is actually running in the cluster (`helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=<cluster> --set region=<region> --set vpcId=<vpc-id>`). `awsLoadBalancerController: true` in the nodegroup's `iam.withAddonPolicies` (see `eks_create_cluster*.yaml`) only grants the node role IAM permissions — it does **not** deploy the controller; without it, `LoadBalancer` Services sit at `<pending>` forever. The `service.beta.kubernetes.io/aws-load-balancer-ssl-cert` annotation is a placeholder — replace `YOUR ACM ARN GOES HERE` with a real ACM cert ARN **in the same AWS account and region as the cluster** (an ARN from another account fails `CreateListener` with a `ValidationError`); if no cert exists yet, comment out both the `ssl-cert` and `ssl-negotiation-policy` annotations and change the `http` Service port from `443` to `80` (plain TCP passthrough to 7474 — port 443 without TLS is misleading, so the LB listens on 80 in that mode) to fall back cleanly to unencrypted HTTP.
- **Images.** `hybrid-core-small.yaml`/`hybrid-gds-small.yaml` use the official multi-arch Neo4j Enterprise image (works on the ARM64 nodegroups here — `m7g`, `r7g`, `r6g` — keep image arch and instance arch aligned if this ever changes). Both files have a commented-out `customImage` pointing at a private ECR repo (`...drose-repo:neo4j-axeb...-enterprise-arm`) in a *different* AWS account (`766746056086`) — don't uncomment it without cross-account ECR pull access, or every pod 403s on `ImagePullBackOff`. That custom image had GDS baked in (built from `docker/axb-debug`/`docker/axbg-debug`, `docker buildx build --platform linux/arm64 ... --push` — see `docker/README.md`); the official image doesn't, so `hybrid-gds-small.yaml`'s `NEO4J_PLUGINS` env var includes `"graph-data-science"` to install it instead.
- **Licenses mounted, not baked.** `gds.enterprise.license_file` / `dbms.bloom.license_file` point at `/licenses/local/*.license`, fed by the `license-config` configmap via `additionalVolumes`/`additionalVolumeMounts`. Bloom is served as an unmanaged extension (`server.unmanaged_extension_classes: com.neo4j.bloom.server=/bloom`).
- **Storage.** `data` and `transactions` volumes use dynamic provisioning against the `gp3highiops` StorageClass (`WaitForFirstConsumer` so PV lands in the pod's AZ; `reclaimPolicy: Retain`). Despite `Retain`, `stopall.sh` explicitly deletes every release's `data-*`/`transactions-*` PVCs *and* their bound PVs on every run — teardown is a full wipe by design here, not an accidental one; `Retain` only prevents the PV from being silently reclaimed by some other process in between. `backup`/`import` volumes bind a shared EFS PVC (`pvc-efs-dynamic`, `sc-efs-dynamic` StorageClass) for RWX access — `stopall.sh` does not touch this one, since it's shared across releases rather than owned by any single one. `startall.sh` provisions the whole EFS stack itself and is idempotent: an EFS filesystem (found/created by a stable creation token `<cluster>-efs`), a security group allowing NFS/2049 from the VPC CIDR, mount targets in every node subnet, and the AWS EFS CSI driver via Helm — then substitutes the real filesystem ID into `storageclass/sc-efs-dynamic.yaml` (checked-in file has a `FILESYSTEM_ID_PLACEHOLDER`, since a real ID from one account/cluster won't exist in another) before applying it and `pvc/efs-pvc-dynamic.yaml`. See `efs-notes/` for the old manual process this replaced. Because the EFS filesystem/mount targets/security group are created directly via the AWS CLI, CloudFormation has no idea they exist; `stopall.sh --all` deletes them explicitly *before* attempting cluster deletion, since a leftover mount-target ENI in a node subnet makes that Subnet resource permanently fail to delete ("has dependencies and cannot be deleted"), leaving the whole cluster CloudFormation stack stuck `DELETE_FAILED`. As a backstop for any other unforeseen leftover dependency, `stopall.sh`'s stack deletions retry with `aws cloudformation delete-stack --deletion-mode FORCE_DELETE_STACK` if the normal deletion doesn't succeed.
- **Cluster topology in config, not chart flags.** PRIMARY/secondary roles come from Neo4j config keys (`initial.server.mode_constraint`, `initial.dbms.default_primaries_count: 3`, `minimumClusterSize: 3`), plus `nodeSelector`/`labels` (`eks.amazonaws.com/nodetype: primary`) to pin members to nodegroups and let LB selectors target them.

## Gotchas

- `stopall.sh` manually deletes leftover `*-cleanup` pods in the `neo4j-ns` namespace after `helm uninstall` — the chart's cleanup jobs don't always clear on their own. Most resources here assume the `neo4j-ns` namespace.
- Release names, values files, and nodegroup names in `scripts/startall.sh`/`stopall.sh` are hardcoded (`neo4j-1..3`, `neo4j-gds-1..2`, `--include=neo4j-ng`); they must stay consistent with `eks_create_cluster*.yaml` nodegroup names, the `nodeSelector` in `hybrid-core-small.yaml`/`hybrid-gds-small.yaml` (must equal `NODEGROUP`), and the `app` label everywhere it's used for selection: `hybrid-core-small.yaml`/`hybrid-gds-small.yaml`'s `neo4j.name` (must match between the two, or GDS secondaries can only discover each other and never join the real cluster — they hang forever on startup with no error), and `lb-neo4j-core.yaml`'s Service `selector.app` (must equal that same `neo4j.name`, or the LB has zero endpoints and every target shows unhealthy with no traffic getting through at all).
- Some Neo4j settings (the `initial.*` namespace — e.g. `initial.dbms.default_primaries_count`, `initial.dbms.automatically_enable_free_servers`) are only read once, at initial DBMS/database bootstrap. A plain `helm upgrade` won't apply a changed value to an already-bootstrapped cluster. If a config change needs a from-scratch bootstrap to take effect, a rolling restart isn't enough — uninstall and let `stopall.sh` wipe the `data`/`transactions` PVs (see Storage above), then reinstall via `startall.sh` so the database initializes fresh with the new settings.
- `stopall.sh` deletes the nodegroup with `--disable-eviction`. When it's the cluster's only nodegroup, `eksctl` cordons every node before draining any of them, so 2-replica `kube-system` deployments behind a PodDisruptionBudget (`coredns`, `ebs-csi-controller`, `metrics-server`) can never reschedule their 2nd replica and block eviction forever ("N pods are unevictable"). `--disable-eviction` bypasses the PDB, which is safe since those pods are being destroyed with the nodegroup anyway.
- `db.tx_log.rotation.retention_policy: "1 hours"` in the values files is a **testing-only** setting — production tx-log retention must match the backup/store-copy strategy.
- `clientSamples/` holds real customer-derived variants (Cilium, external-DNS, blue/green, multi-region LB) — treat as reference snapshots, not the canonical examples.

## Related material

- `monitoring_notes/` — Prometheus/Grafana values for scraping Neo4j metrics (`server.metrics.*` is enabled in the cluster values).
- `clientSamples/externalDNS/` — automating DNS/ACM instead of static LBs (the alternative to this repo's "keep LBs alive" approach).
- `efs-notes/` — shell notes for standing up the AWS EFS CSI driver and the shared PVC.
