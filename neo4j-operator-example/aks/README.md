# Azure AKS

Read [`../README.md`](../README.md) first — it covers what the operator is and how it compares to
the Helm-chart examples. This directory is a stub: it isn't filled in with a CR and StorageClass yet,
unlike [`../eks/`](../eks/README.md).

## What would differ from `../eks/`

The `Neo4j` CR itself (topology, plugins, auth, TLS) is identical across clouds — only the
infrastructure bits the operator doesn't own change:

- **StorageClass.** AKS ships **`managed-csi`** and **`managed-csi-premium`** out of the box —
  unlike EKS, there's no CSI-driver-install or default-class step to reproduce. Set
  `storage.volumes.data.dynamic.storageClassName: managed-csi-premium` on the CR (matching what
  `genericAKS/hybrid-gds/hybrid-core-small.yaml`/`hybrid-gds-small.yaml` use for the Helm-chart
  equivalent) and skip `eks/00-storageclass-gp3.yaml` entirely.
- **LoadBalancer annotations.** The operator CR's `connectivity.service.annotations` would carry
  whatever `genericAKS/hybrid-gds/neo4j-core-lb.yaml`/`neo4j-gds-lb.yaml` set on their standalone LB
  Services today — `service.beta.kubernetes.io/azure-load-balancer-mode` and
  `-azure-load-balancer-internal` — in place of `eks/02-neo4j-cluster.yaml`'s
  `loadBalancerSourceRanges` (Azure's LB annotations don't have a direct source-CIDR equivalent;
  restricting inbound traffic there is an NSG concern instead).
- **Cluster bring-up.** `az aks create` / `az aks get-credentials` in place of `eksctl create
  cluster`, per the operator's own
  [Azure AKS quickstart](https://github.com/neo4j-partners/neo4j-kubernetes-operator/blob/main/docs/user-guide/01-getting-started/azure-aks.md).

Everything else in [`../eks/README.md`](../eks/README.md) — the CRD/chart install, license Secrets,
connect/teardown steps — carries over unchanged.
