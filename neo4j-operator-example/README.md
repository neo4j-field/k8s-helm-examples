# Neo4j Kubernetes Operator example

A second way to run Neo4j on Kubernetes, alongside this repo's Helm-chart-based cloud examples
(`genericEKS/`, `genericAKS/`, `genericGKE/`): [neo4j-partners/neo4j-kubernetes-operator](https://github.com/neo4j-partners/neo4j-kubernetes-operator),
a Kubernetes operator that manages Neo4j as a single custom resource (`kind: Neo4j`) instead of a
Helm release you configure with a values file.

The operator itself is cloud-agnostic — the `Neo4j` CR looks the same everywhere. What differs per
cloud is the handful of infrastructure bits it doesn't own: the StorageClass backing dynamic
volumes, and the LoadBalancer annotations on the client Service. Each is its own subdirectory here,
mirroring the split between `genericEKS/`, `genericAKS/` and `genericGKE/`:

| Directory | Cloud | Status |
|-----------|-------|--------|
| [`eks/`](eks/README.md) | AWS EKS | Worked example — install steps, gp3 StorageClass, `Neo4j` CR |
| [`aks/`](aks/README.md) | Azure AKS | Stub — see its README for what differs from `eks/` |
| [`gke/`](gke/README.md) | Google GKE | Stub — see its README for what differs from `eks/` |

This directory is reference material, like the rest of this repo — not wired into
`genericEKS/scripts/startall.sh`/`stopall.sh`, and not a drop-in replacement for them.

## How this differs from the Helm-chart examples

`genericEKS/` (`neo4j-core.yaml`, `hybrid-neo4j-gds.yaml`, `lb-neo4j-core.yaml`, `lb1-gds.yaml`,
`lb2-gds.yaml`, `scripts/startall.sh`) installs the official `neo4j/neo4j` Helm chart once per
member (or role), with `services.neo4j.enabled: false` and hand-written LB `Service` manifests
standing in front of each one — see `genericEKS/CLAUDE.md`'s "Services disabled in chart, load
balancers external" note for why. The operator collapses that into one declarative object:

- **One `Neo4j` resource, not N Helm releases.** `eks/02-neo4j-cluster.yaml` describes the whole
  topology — 3 primaries plus a GDS secondary pool — that `genericEKS/`'s Helm example builds from
  three separate `helm upgrade -i` calls (`neo4j-core.yaml` x3, `hybrid-neo4j-gds.yaml` x1-2).
- **The operator reconciles continuously**, the way a Kubernetes controller does for any built-in
  resource (Deployment, StatefulSet): it watches the `Neo4j` object and keeps the StatefulSets,
  Services, ConfigMaps, Secrets and PVCs it owns converged to that spec, reporting drift and errors
  back into `status.conditions`. A Helm release is a one-shot template render — `helm upgrade`
  reapplies it, but nothing watches for a manually deleted PVC or an edited ConfigMap in between.
- **One client `Service` in front of the primaries only.** The operator does not (as of this
  writing) publish a separate `LoadBalancer` per secondary pool the way `lb1-gds.yaml`/`lb2-gds.yaml`
  do in `genericEKS/`. That matters specifically for that repo's composite-database GDS routing
  pattern (see `genericEKS/gds-composite-routing-notes.md`): it depends on a non-routing Bolt
  connection straight to the GDS secondary's own NLB, which this CR as written does not reproduce.
  Reaching the GDS pool through the operator today means the in-cluster headless/admin Service, not
  a public per-secondary LB.
- **Licenses as Secrets, not mounted files.** `pluginDefinitions.gds.licenseSecretRef` replaces
  `genericEKS/`'s `license-config` ConfigMap + `additionalVolumes` pattern (`genericEKS/CLAUDE.md`'s
  "Licenses mounted, not baked" note).
- **Feature surface is smaller today.** The operator's own README lists what's implemented:
  Standalone/Cluster topology, storage, connectivity, TLS, auth, config/JVM, plugins, scheduling,
  probes and Prometheus metrics — but *not* backup/restore scheduling as a first-class resource
  beyond what's in `examples/backup/`, version upgrades, Ingress, LDAP or multi-cluster. Check the
  operator's [feature status page](https://github.com/neo4j-partners/neo4j-kubernetes-operator/blob/main/docs/user-guide/01-getting-started/feature-status.md)
  before assuming a `genericEKS/` capability (e.g. the EFS-backed shared `backup`/`import` volume,
  or per-domain nodegroup pinning) has an operator equivalent.

## How a Kubernetes operator works, and its tradeoffs

A **Kubernetes operator** is application-specific automation built on the same control-loop pattern
Kubernetes itself uses for every built-in resource:

1. A **Custom Resource Definition (CRD)** teaches the API server a new resource type - here,
   `kind: Neo4j` under `neo4j.com/v1`. Once installed, `kubectl apply -f eks/02-neo4j-cluster.yaml`
   is stored in etcd exactly like a Deployment or Service would be, including admission validation
   (the CRD's schema is why `loadBalancerSourceRanges` is *required* the moment
   `service.type: LoadBalancer` is set — that's enforced before the object is even accepted).
2. A **controller** (the pod(s) installed by `helm upgrade --install neo4j-operator ...`) runs a
   reconcile loop: watch `Neo4j` objects for changes, compare the desired spec against the actual
   StatefulSets/Services/ConfigMaps/Secrets/PVCs it owns, and issue the create/update/delete calls
   needed to close the gap. It keeps doing this forever, not just at `kubectl apply` time — the
   defining difference from a Helm chart, which only acts when you run `helm upgrade`.
3. **Status is reported back onto the object itself.** `kubectl get neo4j <name>` and
   `status.conditions` give you a live, structured answer to "is this actually working," derived
   from what the controller observed on its last reconcile — not just "did the last `helm upgrade`
   command exit zero."

**Pros:**

- **Encodes operational knowledge, not just templates.** A Helm chart renders YAML from values; an
  operator can also *act* — e.g. detecting a config change that needs a from-scratch bootstrap
  (`genericEKS/`'s `initial.*` settings gotcha) and handling the sequencing, rather than leaving it
  to a paragraph in `genericEKS/CLAUDE.md` that a human has to remember.
- **Self-healing.** Because reconciliation is continuous, drift (someone hand-edits a ConfigMap,
  deletes a PVC) gets corrected on the next loop instead of silently persisting until the next
  `helm upgrade`.
- **A native API, not a scripting convention.** `kubectl get neo4j`, `kubectl describe neo4j`,
  RBAC scoped to the `neo4j.com` API group, and (per the operator's docs) Kubernetes Events all work
  the way they do for any built-in resource — nothing `genericEKS/scripts/startall.sh`/`stopall.sh`
  had to build by hand (deployment.env bookkeeping, glob-matching `deployed-*/` directories, etc.).
- **Higher-level abstraction over multi-resource topologies.** One `Neo4j` object replaces the
  several Helm releases plus standalone LB manifests `genericEKS/` currently needs for a hybrid
  core+GDS cluster.
- **The same CR works across clouds.** `eks/02-neo4j-cluster.yaml` only differs from an AKS or GKE
  version in `storageClassName` and the LoadBalancer annotations — versus `genericEKS/`,
  `genericAKS/` and `genericGKE/` being three separately maintained sets of values files and LB
  manifests today.

**Cons:**

- **Another moving part with its own lifecycle.** The operator, its CRDs and its RBAC have to be
  installed, upgraded and watched for bugs, independent of Neo4j's own version. A stuck or crashed
  controller pod means *nothing* reconciles, even though every existing StatefulSet keeps running.
- **A narrower, newer feature surface.** As of this operator's current release, several things
  `genericEKS/` relies on for its hybrid GDS design aren't there yet (a per-secondary public
  LoadBalancer, the EFS-backed shared `backup`/`import` volume, per-domain nodegroup pinning via
  `startall.sh`'s flags) — you're bounded by what the CRD's schema and controller actually
  implement, versus a Helm chart plus your own manifests where anything Kubernetes can express is
  fair game.
- **Less transparent under the hood.** With the Helm example, every Service/StatefulSet/ConfigMap in
  `genericEKS/` is a checked-in file you can read end to end. With the operator, most of that is
  generated at runtime from the CR by controller code you don't control — debugging means reading
  `status.conditions`/Events and, if those don't explain it, the operator's own source or issue
  tracker, rather than a YAML file in this directory.
- **CRD installation is cluster-scoped and versioned separately from the app.** Upgrading the
  operator to a new CRD version is a distinct, cluster-wide operation (`kubectl apply --server-side
  --force-conflicts -f neo4j-crd-<version>.yaml`) that every `Neo4j` object in every namespace is
  affected by — there's no per-namespace or per-release CRD pinning the way a Helm chart version is
  scoped to its own release.
- **Trust boundary.** The controller runs with RBAC broad enough to create/delete StatefulSets,
  Services, Secrets and PVCs across whatever it's scoped to watch — worth reviewing before granting
  it a wider `--namespace` scope than `default`.
