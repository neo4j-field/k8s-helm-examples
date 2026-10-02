# Google GKE

Read [`../README.md`](../README.md) first — it covers what the operator is and how it compares to
the Helm-chart examples. This directory is a stub: it isn't filled in with a CR and StorageClass yet,
unlike [`../eks/`](../eks/README.md).

## What would differ from `../eks/`

The `Neo4j` CR itself (topology, plugins, auth, TLS) is identical across clouds — only the
infrastructure bits the operator doesn't own change:

- **StorageClass.** GKE ships **`standard-rwo`** (pd-balanced, the default) and **`premium-rwo`**
  out of the box — unlike EKS, there's no CSI-driver-install or default-class step to reproduce. Set
  `storage.volumes.data.dynamic.storageClassName: premium-rwo` on the CR (`genericGKE/standalone.yaml`
  uses a custom `neo4j-ssd` class for its Helm-chart equivalent — see `genericGKE/storageclass/` and
  `genericGKE/createStorageClass.sh` if reproducing that here instead) and skip
  `eks/00-storageclass-gp3.yaml` entirely.
- **LoadBalancer annotations.** In place of `eks/02-neo4j-cluster.yaml`'s
  `loadBalancerSourceRanges`, GKE's client-Service annotation is
  `networking.gke.io/load-balancer-type: "External"` (or `"Internal"`) — see
  `genericGKE/standalone-lb.yaml` for the plain-Service version of the same choice.
- **Cluster bring-up.** `gcloud container clusters create` / `gcloud container clusters
  get-credentials` in place of `eksctl create cluster`, per the operator's own
  [GKE quickstart](https://github.com/neo4j-partners/neo4j-kubernetes-operator/blob/main/docs/user-guide/01-getting-started/gcp-gke.md),
  including installing `gke-gcloud-auth-plugin` — `kubectl` cannot authenticate to GKE without it.

Everything else in [`../eks/README.md`](../eks/README.md) — the CRD/chart install, license Secrets,
connect/teardown steps — carries over unchanged.
