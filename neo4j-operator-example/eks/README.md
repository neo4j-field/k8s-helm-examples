# AWS EKS

Read [`../README.md`](../README.md) first — it covers what the operator is, how it compares to
`genericEKS/`'s Helm-chart approach, and the operator's general pros/cons. This page is just the
EKS-specific install steps.

## What's here

| File | Purpose |
|------|---------|
| [`00-storageclass-gp3.yaml`](00-storageclass-gp3.yaml) | `gp3` StorageClass, set as cluster default — EKS ships neither a CSI driver nor a default class |
| [`02-neo4j-cluster.yaml`](02-neo4j-cluster.yaml) | The `Neo4j` custom resource: 3 primaries + 1 GDS/Bloom secondary, `LoadBalancer` client Service |
| [`licenses/`](licenses/) | Gitignored scratch folder for your real `.license` files, used in step 4 below |

## Prerequisites

- `kubectl`, `helm` 3.8+, `eksctl`.
- Real GDS/Bloom license files — step 4 below creates their Secrets imperatively, so the license
  text never lands in a tracked file (or drop the `secondaries.analytics` block in
  [`02-neo4j-cluster.yaml`](02-neo4j-cluster.yaml) entirely for a plain 3-primary cluster with no
  GDS, and skip licenses altogether).

## 1. Create the EKS cluster

`genericEKS/scripts/startall.sh --k8s` provisions everything this operator needs below the
`Neo4j` CR itself — the EKS cluster, its nodegroup, and the AWS EBS CSI driver addon + IAM role
that dynamic storage depends on:

```bash
cd ../../genericEKS
scripts/startall.sh --k8s
cd -
```

This defaults to a cluster named `jhair-cluster`; pass `--cluster-name` to use a different one. If
you already have an EKS cluster with the EBS CSI driver installed, skip this step — the operator
repo's own [AWS EKS quickstart](https://github.com/neo4j-partners/neo4j-kubernetes-operator/blob/main/docs/user-guide/01-getting-started/aws-eks.md)
covers creating one from scratch without `genericEKS/`.

## 2. Create and switch to a dedicated namespace

`startall.sh --k8s` leaves your `kubectl` context pointed at its own namespace (`neo4j-ns` by
default, or `<domain>-ns` if you passed `--domain-name`). Use a separate namespace for this
example instead of reusing that one, so a `genericEKS/` Helm-deployed cluster and this
operator-managed one never collide:

```bash
kubectl create namespace neo4j-operator-demo
kubectl config set-context --current --namespace=neo4j-operator-demo
```

Every command below assumes this is your current namespace, so none of them pass `-n` explicitly.

## 3. Install the operator

The controller only reconciles `Neo4j` objects in namespaces it's told to watch — by default just
`default` — so point it at `neo4j-operator-demo` via `watchNamespaces`, or the CR from step 5 will
sit there accepted-but-never-reconciled (`kubectl apply` succeeds, but no pods, no
`status.conditions`, no Events: that's the symptom if this step gets skipped):

```bash
# The CRDs, then the controller - take VERSION from the operator's latest release
VERSION=1.0.0
kubectl apply --server-side --force-conflicts \
  -f https://github.com/neo4j-partners/neo4j-kubernetes-operator/releases/download/v${VERSION}/neo4j-crd-${VERSION}.yaml

helm upgrade --install neo4j-operator \
  oci://ghcr.io/neo4j-partners/charts/neo4j-operator --version ${VERSION} \
  --namespace neo4j-operator-system --create-namespace --wait \
  --set "watchNamespaces[0]=neo4j-operator-demo"
```

Confirm it took:

```bash
kubectl logs -n neo4j-operator-system deploy/neo4j-operator-controller-manager | grep "watching namespaces"
# {"...,"msg":"watching namespaces","namespaces":["neo4j-operator-demo"]}
```

## 4. StorageClass and license Secrets

```bash
# gp3 StorageClass (skip if this cluster already has a default gp3 class) - cluster-scoped, no
# namespace involved
kubectl apply -f 00-storageclass-gp3.yaml

# License Secrets, created imperatively so the license text never lands in a tracked file - drop
# your real files in licenses/ first (licenses/*.license is gitignored, same convention as
# genericEKS/.gitignore's identical rule)
cp /path/to/your/gds.license   licenses/gds.license
cp /path/to/your/bloom.license licenses/bloom.license

kubectl create secret generic gds-license --from-file=license=licenses/gds.license
kubectl label secret gds-license neo4j.com/mountable-by-operator=true

kubectl create secret generic bloom-license --from-file=license=licenses/bloom.license
kubectl label secret bloom-license neo4j.com/mountable-by-operator=true
```

## 5. Deploy the cluster

```bash
kubectl apply -f 02-neo4j-cluster.yaml
kubectl get neo4j jhair-cluster -w
kubectl get pods -l app.kubernetes.io/instance=jhair-cluster
```

**If no pods show up and `status.conditions`/`kubectl describe neo4j jhair-cluster`'s Events are
both empty**, the CR was accepted by the API server but nothing is reconciling it — almost always
step 3's `watchNamespaces` missing `neo4j-operator-demo`. Confirm with:

```bash
kubectl logs -n neo4j-operator-system deploy/neo4j-operator-controller-manager | grep "watching namespaces"
```

and fix it without touching the CR — `helm upgrade` with the `--set watchNamespaces...` from step 3
again picks up the existing `jhair-cluster` object on its next reconcile loop; no need to delete or
reapply anything.

## Connect

Once `status.conditions[Ready]` is `True`, get credentials and port-forward for a quick local
check:

```bash
kubectl get secret jhair-cluster-auth -o jsonpath='{.data.NEO4J_AUTH}' | base64 -d; echo
kubectl port-forward svc/jhair-cluster 7687:7687 7474:7474
```

### Connecting from outside EKS

`kubectl get svc jhair-cluster` shows a public ELB hostname almost immediately, but
`02-neo4j-cluster.yaml`'s `loadBalancerSourceRanges: ["10.0.0.0/8"]` is a **private** RFC1918 CIDR
(VPC-internal) — so the ELB exists and resolves publicly, but its security group drops everything
from outside the VPC with no visible error. "It's `Ready: True` but I can't reach it from my
laptop" is this, not a deployment problem. Find your public IP and patch it in:

```bash
MY_IP="$(curl -s https://checkip.amazonaws.com)"
kubectl patch neo4j jhair-cluster --type merge \
  -p "{\"spec\":{\"connectivity\":{\"service\":{\"loadBalancerSourceRanges\":[\"${MY_IP}/32\"]}}}}"
```

Then connect with the ELB hostname from `kubectl get svc jhair-cluster` in place of `localhost`:

```bash
kubectl get svc jhair-cluster -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
# neo4j://<that hostname>:7687 and http://<that hostname>:7474, same credentials as above
```

## Tear down

Delete the Neo4j resources (and their PVCs, so EBS volumes don't linger and keep billing) before
the namespace or the cluster:

```bash
kubectl delete -f 02-neo4j-cluster.yaml
kubectl delete pvc -l app.kubernetes.io/instance=jhair-cluster
kubectl delete namespace neo4j-operator-demo
```

If you created the EKS cluster in step 1 purely for this example *and nothing else is running on
it* (e.g. no `genericEKS/` Helm-deployed cluster in another namespace), tear it down too with
`genericEKS/scripts/stopall.sh --all` — but note that's a full wipe of the cluster itself, so skip
it if the cluster is shared with a deployment you want to keep.
