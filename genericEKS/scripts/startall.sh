#!/usr/bin/env bash
#
# Bring up the hybrid GDS cluster on EKS end to end:
#   nodegroup -> namespace -> secret/licenses -> EFS filesystem/CSI driver ->
#   storage classes/PVCs -> pods -> load balancers
#
# Run from anywhere; the script cd's to the genericEKS root itself.
#   ./scripts/startall.sh [MODE] [OPTIONS]
#
# Modes (default: --all, runs to completion with no prompts):
#   --k8s          Provision only the EKS cluster/nodegroup/namespace/EFS/
#                  storage prerequisites. Skips Neo4j helm installs, load
#                  balancers, and the LB-hostname/connection-URL wait.
#   --all          Full pipeline: k8s infrastructure + Neo4j installs +
#                  load balancers. This is also what runs with no
#                  arguments at all.
#
# Options:
#   --cluster-name NAME    EKS cluster name (default: jhair-cluster). The
#                           checked-in eksctl ClusterConfig hardcodes
#                           metadata.name -- eksctl refuses --name alongside
#                           --config-file, so a custom name here is applied
#                           by writing a temp copy of the config with
#                           metadata.name substituted.
#   --release-name PREFIX  Helm release name prefix (default: neo4j),
#                           producing PREFIX-1/2/3 (core) and
#                           PREFIX-gds-1/2 (GDS). The GDS load balancer
#                           manifests select pods by this exact release
#                           name, so a temp copy of those manifests is
#                           applied with the substituted name too.
#   -h, --help              Show this help and exit.
#
# Stops immediately on any command failure (set -e/-o pipefail), including
# failures inside a `cmd | kubectl apply -f -` pipeline.
set -euo pipefail
trap 'echo "ERROR: command failed (exit $?) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
# aws-cli v2 pipes JSON responses through a pager (less) by default when run
# in an interactive terminal, which silently hangs this script waiting for a
# keypress on any of the many `aws ...` calls below that don't set --output.
export AWS_PAGER=""

# ---------------------------------------------------------------------------
# Mode selection
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: startall.sh [MODE] [OPTIONS]

Bring up the hybrid GDS Neo4j cluster on EKS.

Modes (default: --all, runs to completion with no prompts):
  --k8s                   Provision only the EKS cluster/nodegroup/namespace/
                          EFS/storage prerequisites. Skips Neo4j helm
                          installs, load balancers, and the LB-hostname/
                          connection-URL wait.
  --all                   Full pipeline: k8s infrastructure + Neo4j installs
                          + load balancers. This is also what runs with no
                          arguments at all.

Options:
  --cluster-name NAME     EKS cluster name (default: jhair-cluster).
  --release-name PREFIX   Helm release name prefix (default: neo4j),
                          producing PREFIX-1/2/3 (core) and PREFIX-gds-1/2
                          (GDS).
  --gds-count N           Number of GDS secondary members: 0, 1, or 2
                          (default: 0 -- GDS is opt-in). 0 skips GDS
                          entirely -- no GDS installs, no GDS load
                          balancers.
  -h, --help              Show this help and exit.
EOF
}

MODE="full"
CLUSTER_NAME_ARG=""
RELEASE_PREFIX_ARG=""
GDS_COUNT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) MODE="k8s-only"; shift ;;
    --all) MODE="full"; shift ;;
    --cluster-name)
      if [[ -z "${2:-}" ]]; then echo "ERROR: --cluster-name requires a value" >&2; usage; exit 1; fi
      CLUSTER_NAME_ARG="$2"; shift 2 ;;
    --release-name)
      if [[ -z "${2:-}" ]]; then echo "ERROR: --release-name requires a value" >&2; usage; exit 1; fi
      RELEASE_PREFIX_ARG="$2"; shift 2 ;;
    --gds-count)
      if [[ ! "${2:-}" =~ ^[0-2]$ ]]; then echo "ERROR: --gds-count requires a value of 0, 1, or 2" >&2; usage; exit 1; fi
      GDS_COUNT_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_CONFIG="eks_create_cluster-jhair.yaml"           # eksctl ClusterConfig holding the nodegroup
EKS_CLUSTER_NAME="${CLUSTER_NAME_ARG:-jhair-cluster}"    # metadata.name in CLUSTER_CONFIG (overridable via --cluster-name)
EKS_REGION="us-east-2"                       # metadata.region in CLUSTER_CONFIG
NODEGROUP="neo4j-ng"                         # nodegroup to spin up (must exist in CLUSTER_CONFIG)
NAMESPACE="neo4j-ns"                         # must match the namespace in the *-lb.yaml manifests

CORE_VALUES="neo4j-core.yaml"                # 3 core PRIMARY members
GDS_VALUES="hybrid-neo4j-gds.yaml"           # up to 2 secondary GDS members
CORE_COUNT=3
GDS_COUNT="${GDS_COUNT_ARG:-0}"              # 0/1/2 secondary GDS members (opt-in, overridable via --gds-count)

CORE_LB="lb-neo4j-core.yaml"                 # 1 NLB fronting the core members
GDS_LBS_ALL=(lb1-gds.yaml lb2-gds.yaml)      # 1 NLB per GDS member (non-routing bolt)
GDS_LBS=("${GDS_LBS_ALL[@]:0:GDS_COUNT}")    # only as many LBs as GDS members requested

RELEASE_PREFIX="${RELEASE_PREFIX_ARG:-neo4j}"  # Helm release name prefix (overridable via --release-name)

NEO4J_AUTH="neo4j/Neo4j123"                  # username/password for the neo4jpwd secret

SLEEP_BETWEEN=10                             # pause between helm installs

# NOTE: the nodeSelector in ${CORE_VALUES}/${GDS_VALUES}
#       (eks.amazonaws.com/nodegroup: ...) MUST match ${NODEGROUP} above,
#       or the pods will stay Pending (unschedulable).

# ---------------------------------------------------------------------------
# cd to the genericEKS root (parent of this script's dir) so relative paths work
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# ---------------------------------------------------------------------------
# Scratch space for files generated during a deployment (gitignored -- see
# .gitignore). Named per cluster+release so multiple concurrent deployments
# (different --cluster-name/--release-name) each get their own directory
# instead of overwriting one shared one. If a custom cluster name was
# requested, eksctl refuses --name alongside --config-file, so write a temp
# copy of CLUSTER_CONFIG here with metadata.name substituted and use that
# instead everywhere eksctl reads CLUSTER_CONFIG.
# ---------------------------------------------------------------------------
SCRATCH_DIR="deployed-${EKS_CLUSTER_NAME}-${RELEASE_PREFIX}"
mkdir -p "${SCRATCH_DIR}"
if [[ -n "${CLUSTER_NAME_ARG}" ]]; then
  TMP_CLUSTER_CONFIG="$(mktemp "${SCRATCH_DIR}/eks-cluster-config.XXXXXX.yaml")"
  trap 'rm -f "${TMP_CLUSTER_CONFIG}"' EXIT
  sed "s/^  name: .*/  name: ${EKS_CLUSTER_NAME}/" "${CLUSTER_CONFIG}" > "${TMP_CLUSTER_CONFIG}"
  CLUSTER_CONFIG="${TMP_CLUSTER_CONFIG}"
fi

# Record what this deployment actually used so stopall.sh can tear down the
# right cluster/releases/GDS count later without --cluster-name/
# --release-name/--gds-count having to be repeated (and possibly getting out
# of sync) on the stopall.sh command line. One file per cluster+release, so
# deploying multiple clusters/release-prefixes doesn't clobber each other's
# record -- stopall.sh picks the right deployed-*/ directory by name.
DEPLOYMENT_STATE_FILE="${SCRATCH_DIR}/deployment.env"
cat > "${DEPLOYMENT_STATE_FILE}" <<EOF
EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}
EKS_REGION=${EKS_REGION}
NODEGROUP=${NODEGROUP}
NAMESPACE=${NAMESPACE}
RELEASE_PREFIX=${RELEASE_PREFIX}
GDS_COUNT=${GDS_COUNT}
EOF

# ---------------------------------------------------------------------------
# 0. AWS auth + kubectl context (this box is also used against AKS clusters,
#    so kubectl's current-context may be pointed elsewhere)
# ---------------------------------------------------------------------------
echo "Checking AWS SSO session..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS SSO session expired or missing; running 'aws sso login'..."
  aws sso login
fi

echo "Checking whether EKS cluster (${EKS_CLUSTER_NAME}) exists..."
if ! aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}" >/dev/null 2>&1; then
  # The EKS cluster resource itself can disappear from the API/console well
  # before its CloudFormation stack (VPC, NAT gateway, subnets, security
  # groups) finishes tearing down after a `stopall.sh --neo4j-and-k8s` run.
  # Creating a new stack with the same name while the old one is still
  # DELETE_IN_PROGRESS fails with a confusing AlreadyExistsException, so wait
  # it out first if that's the case.
  CLUSTER_STACK="eksctl-${EKS_CLUSTER_NAME}-cluster"
  # describe-stacks exits non-zero (and would trip set -e) when the stack
  # doesn't exist at all, which is the common case -- treat that as "no
  # status" rather than letting it abort the script.
  STACK_STATUS="$(aws cloudformation describe-stacks --region "${EKS_REGION}" --stack-name "${CLUSTER_STACK}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" || STACK_STATUS=""
  if [[ "${STACK_STATUS}" == "DELETE_IN_PROGRESS" ]]; then
    echo "Stack ${CLUSTER_STACK} is still ${STACK_STATUS} from a prior teardown; waiting for it to finish..."
    aws cloudformation wait stack-delete-complete --region "${EKS_REGION}" --stack-name "${CLUSTER_STACK}"
    echo "Stack ${CLUSTER_STACK} finished deleting."
  fi

  echo "Cluster not found; creating it from ${CLUSTER_CONFIG} (this takes ~15-20 minutes)..."
  eksctl create cluster --config-file="${CLUSTER_CONFIG}" --without-nodegroup
else
  echo "Cluster ${EKS_CLUSTER_NAME} already exists."
fi

echo "Pointing kubectl at EKS cluster (${EKS_CLUSTER_NAME}, ${EKS_REGION})..."
if ! timeout 30 aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}"; then
  echo "ERROR: 'aws eks update-kubeconfig' timed out or failed after 30s. Check network/AWS SSO auth (it may be waiting on a prompt) and retry." >&2
  exit 1
fi

CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "${CURRENT_CONTEXT}" != *"${EKS_CLUSTER_NAME}"* ]]; then
  echo "ERROR: kubectl context is '${CURRENT_CONTEXT}', expected it to reference '${EKS_CLUSTER_NAME}'. Aborting." >&2
  exit 1
fi
echo "kubectl context confirmed: ${CURRENT_CONTEXT}"

# ---------------------------------------------------------------------------
# 1. Nodegroup
# ---------------------------------------------------------------------------
echo "Checking whether nodegroup (${NODEGROUP}) exists..."
if aws eks describe-nodegroup --cluster-name "${EKS_CLUSTER_NAME}" --nodegroup-name "${NODEGROUP}" --region "${EKS_REGION}" >/dev/null 2>&1; then
  echo "Nodegroup ${NODEGROUP} already exists."
else
  echo "Creating nodegroup (${NODEGROUP}) from ${CLUSTER_CONFIG}..."
  eksctl create nodegroup --config-file="${CLUSTER_CONFIG}" --include="${NODEGROUP}"
fi

# ---------------------------------------------------------------------------
# 2. Namespace (created before use; pods and load balancers share it)
# ---------------------------------------------------------------------------
echo "Ensuring namespace (${NAMESPACE}) exists..."
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl config set-context --current --namespace="${NAMESPACE}"

# ---------------------------------------------------------------------------
# 3. Prerequisites: auth secret, license configmap (idempotent)
# ---------------------------------------------------------------------------
echo "Ensuring auth secret (neo4jpwd)..."
kubectl create secret generic neo4jpwd \
  --from-literal="NEO4J_AUTH=${NEO4J_AUTH}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
# pipefail (set above) ensures a failure in either half of the pipe aborts the script

echo "Ensuring license configmap (license-config)..."
kubectl create configmap license-config \
  --from-file=licenses/ \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Waiting for at least one Ready node labeled eks.amazonaws.com/nodegroup=${NODEGROUP}..."
for i in $(seq 1 30); do
  READY_NODE=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2=="True"{print $1; exit}')
  if [[ -n "${READY_NODE}" ]]; then
    echo "Node ${READY_NODE} is Ready."
    break
  fi
  sleep 5
done
if [[ -z "${READY_NODE}" ]]; then
  echo "ERROR: no Ready node labeled eks.amazonaws.com/nodegroup=${NODEGROUP} after 150s." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3b. Shared EFS filesystem for the import/backup volume (pvc-efs-dynamic).
#     Fully idempotent: safe to re-run against an existing filesystem/mount
#     targets/security group. Needs real node subnets, so this must run after
#     nodes exist (above) and before storage classes/PVCs are applied (below).
# ---------------------------------------------------------------------------
EFS_CREATION_TOKEN="${EKS_CLUSTER_NAME}-efs"
EFS_SG_NAME="${EKS_CLUSTER_NAME}-efs-sg"

echo "Ensuring EFS filesystem (creation token ${EFS_CREATION_TOKEN})..."
EFS_ID="$(aws efs describe-file-systems --region "${EKS_REGION}" \
  --query "FileSystems[?CreationToken=='${EFS_CREATION_TOKEN}'].FileSystemId | [0]" --output text)"
if [[ "${EFS_ID}" == "None" || -z "${EFS_ID}" ]]; then
  echo "Creating EFS filesystem..."
  EFS_ID="$(aws efs create-file-system --region "${EKS_REGION}" \
    --creation-token "${EFS_CREATION_TOKEN}" \
    --performance-mode generalPurpose \
    --tags "Key=Name,Value=${EFS_CREATION_TOKEN}" \
    --query 'FileSystemId' --output text)"
  echo "Waiting for EFS filesystem ${EFS_ID} to become available..."
  # the aws-cli "efs" service has no "wait" subcommand (unlike ec2/eks), so poll manually
  for _ in $(seq 1 20); do
    FS_STATE="$(aws efs describe-file-systems --region "${EKS_REGION}" --file-system-id "${EFS_ID}" \
      --query 'FileSystems[0].LifeCycleState' --output text)"
    [[ "${FS_STATE}" == "available" ]] && break
    sleep 15
  done
  if [[ "${FS_STATE}" != "available" ]]; then
    echo "ERROR: EFS filesystem ${EFS_ID} did not become available (last state: ${FS_STATE})." >&2
    exit 1
  fi
else
  echo "EFS filesystem ${EFS_ID} already exists."
fi

VPC_ID="$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
VPC_CIDR="$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${EKS_REGION}" \
  --query 'Vpcs[0].CidrBlock' --output text)"

echo "Ensuring EFS security group (${EFS_SG_NAME})..."
EFS_SG_ID="$(aws ec2 describe-security-groups --region "${EKS_REGION}" \
  --filters "Name=group-name,Values=${EFS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "${EFS_SG_ID}" == "None" || -z "${EFS_SG_ID}" ]]; then
  echo "Creating EFS security group..."
  EFS_SG_ID="$(aws ec2 create-security-group --region "${EKS_REGION}" \
    --group-name "${EFS_SG_NAME}" --description "NFS (2049) access for ${EFS_CREATION_TOKEN}" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --region "${EKS_REGION}" \
    --group-id "${EFS_SG_ID}" --protocol tcp --port 2049 --cidr "${VPC_CIDR}"
else
  echo "Security group ${EFS_SG_ID} already exists."
fi

echo "Ensuring EFS mount targets exist in every node subnet..."
NODE_SUBNETS="$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP}" \
  -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ '{print $NF}' \
  | while read -r instance_id; do
      aws ec2 describe-instances --region "${EKS_REGION}" --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].SubnetId' --output text
    done | sort -u)"

EXISTING_MT_SUBNETS="$(aws efs describe-mount-targets --region "${EKS_REGION}" \
  --file-system-id "${EFS_ID}" --query 'MountTargets[].SubnetId' --output text)"

for subnet in ${NODE_SUBNETS}; do
  if echo "${EXISTING_MT_SUBNETS}" | tr '\t' '\n' | grep -qx "${subnet}"; then
    echo "Mount target already exists in ${subnet}."
  else
    echo "Creating mount target in ${subnet}..."
    aws efs create-mount-target --region "${EKS_REGION}" \
      --file-system-id "${EFS_ID}" --subnet-id "${subnet}" --security-groups "${EFS_SG_ID}"
  fi
done

echo "Waiting for EFS mount targets to become available..."
for _ in $(seq 1 20); do
  MT_STATES="$(aws efs describe-mount-targets --region "${EKS_REGION}" --file-system-id "${EFS_ID}" \
    --query 'MountTargets[].LifeCycleState' --output text)"
  if ! echo "${MT_STATES}" | tr '\t' '\n' | grep -qv "available"; then
    echo "All mount targets available."
    break
  fi
  sleep 15
done

echo "Ensuring AWS EFS CSI driver is installed..."
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ >/dev/null 2>&1 || true
helm repo update aws-efs-csi-driver >/dev/null
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system --wait --timeout 5m

# ---------------------------------------------------------------------------
# 3c. Storage classes + the shared EFS PVC (depends on EFS_ID above)
# ---------------------------------------------------------------------------
echo "Applying storage classes..."
bash create_storageclass.sh "${EFS_ID}"

echo "Ensuring shared EFS PVC (pvc-efs-dynamic)..."
kubectl apply -f pvc/efs-pvc-dynamic.yaml

if [[ "${MODE}" == "k8s-only" ]]; then
  echo "-------------------------------------------------------"
  echo "--k8s: Kubernetes infrastructure is ready (cluster, nodegroup,"
  echo "namespace, secret/licenses, EFS, storage classes/PVC). Neo4j was NOT"
  echo "installed and no load balancers were created."
  echo "Run '$(basename "$0") --all' (or with no arguments) to install Neo4j."
  echo "-------------------------------------------------------"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Neo4j members
# ---------------------------------------------------------------------------
echo "Installing ${CORE_COUNT} core member(s)..."
for i in $(seq 1 "${CORE_COUNT}"); do
  helm upgrade -i "${RELEASE_PREFIX}-${i}" neo4j/neo4j --namespace "${NAMESPACE}" -f "${CORE_VALUES}"
  sleep "${SLEEP_BETWEEN}"
done

if [[ "${GDS_COUNT}" -gt 0 ]]; then
  echo "Installing ${GDS_COUNT} GDS member(s)..."
  for i in $(seq 1 "${GDS_COUNT}"); do
    helm upgrade -i "${RELEASE_PREFIX}-gds-${i}" neo4j/neo4j --namespace "${NAMESPACE}" -f "${GDS_VALUES}"
    sleep "${SLEEP_BETWEEN}"
  done
else
  echo "Skipping GDS members (pass --gds-count 1 or 2 to deploy them)."
fi

# ---------------------------------------------------------------------------
# 5. Load balancers
# ---------------------------------------------------------------------------
echo "Creating load balancers..."
kubectl apply -f "${CORE_LB}"
for i in "${!GDS_LBS[@]}"; do
  gds_num=$((i+1))
  # The GDS LB manifests select pods by the exact release name
  # (helm.neo4j.com/instance) -- substitute it if --release-name changed
  # that from the checked-in default "neo4j" (leaves the LB's own object
  # name, e.g. "neo4j-gds-1-lb", untouched -- that's a separate identity).
  sed "/helm\.neo4j\.com\/instance:/s/neo4j-gds-${gds_num}/${RELEASE_PREFIX}-gds-${gds_num}/" \
    "${GDS_LBS[$i]}" | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# 6. Status + next step
# ---------------------------------------------------------------------------
echo "-------------------------------------------------------"
echo "kubectl get pods -n ${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}"
echo
echo "kubectl get svc -n ${NAMESPACE}"
kubectl get svc -n "${NAMESPACE}"
echo "-------------------------------------------------------"

# ---------------------------------------------------------------------------
# 7. Wait for LB hostnames and print connection URLs
# ---------------------------------------------------------------------------
wait_for_lb_hostname() {
  local svc="$1"
  local hostname=""
  for _ in $(seq 1 40); do
    hostname="$(kubectl get svc "${svc}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    [[ -n "${hostname}" ]] && break
    sleep 15
  done
  echo "${hostname}"
}

# Scheme depends on whether TLS termination is enabled (uncommented ssl-cert
# annotation) in the manifest that created the LB -- see CLAUDE.md/"LBs require
# AWS Load Balancer Controller" for why this may be plain TCP passthrough.
lb_uses_tls() {
  grep -qE '^\s*service\.beta\.kubernetes\.io/aws-load-balancer-ssl-cert:' "$1"
}

echo "Waiting for load balancer hostnames (this can take a few minutes)..."
CORE_LB_SVC="$(grep -m1 '^\s*name:' "${CORE_LB}" | awk '{print $2}')"
CORE_HOST="$(wait_for_lb_hostname "${CORE_LB_SVC}")"
if lb_uses_tls "${CORE_LB}"; then CORE_SCHEME_BOLT="bolt+s"; CORE_SCHEME_HTTP="https"; else CORE_SCHEME_BOLT="bolt"; CORE_SCHEME_HTTP="http"; fi

GDS_HOSTS=()
GDS_SCHEMES=()
for lb in "${GDS_LBS[@]}"; do
  svc="$(grep -m1 '^\s*name:' "${lb}" | awk '{print $2}')"
  host="$(wait_for_lb_hostname "${svc}")"
  GDS_HOSTS+=("${host}")
  if lb_uses_tls "${lb}"; then GDS_SCHEMES+=("bolt+s https"); else GDS_SCHEMES+=("bolt http"); fi
done

echo "-------------------------------------------------------"
echo "Neo4j connection URLs:"
echo
if [[ -n "${CORE_HOST}" ]]; then
  echo "Core cluster (${CORE_COUNT} PRIMARY members, via ${CORE_LB_SVC}):"
  echo "  Bolt:    ${CORE_SCHEME_BOLT}://${CORE_HOST}:7687"
  echo "  Browser: ${CORE_SCHEME_HTTP}://${CORE_HOST}"
else
  echo "Core LB (${CORE_LB_SVC}) has no hostname yet -- check with:"
  echo "  kubectl get svc ${CORE_LB_SVC} -n ${NAMESPACE}"
fi
echo
for i in "${!GDS_LBS[@]}"; do
  svc="$(grep -m1 '^\s*name:' "${GDS_LBS[$i]}" | awk '{print $2}')"
  host="${GDS_HOSTS[$i]}"
  read -r bolt_scheme http_scheme <<< "${GDS_SCHEMES[$i]}"
  if [[ -n "${host}" ]]; then
    echo "GDS secondary $((i+1)) (via ${svc}, non-routing Bolt for GDS calls):"
    echo "  Bolt:    ${bolt_scheme}://${host}:7687"
    echo "  Browser: ${http_scheme}://${host}"
  else
    echo "GDS LB (${svc}) has no hostname yet -- check with:"
    echo "  kubectl get svc ${svc} -n ${NAMESPACE}"
  fi
done
echo "-------------------------------------------------------"
if [[ "${GDS_COUNT}" -gt 0 ]]; then
  echo "Once all pods are Running, set the topology so the DB replicates"
  echo "to the GDS secondaries (run against the core LB / a core pod):"
  echo
  echo "  ALTER DATABASE neo4j SET TOPOLOGY ${CORE_COUNT} PRIMARY ${GDS_COUNT} SECONDARY"
  echo "-------------------------------------------------------"
fi
if [[ -n "${CORE_HOST}" ]]; then
  echo "Neo4j Browser: ${CORE_SCHEME_HTTP}://${CORE_HOST}"
else
  echo "Neo4j Browser: not available yet -- core LB has no hostname (see above)."
fi
echo "Login:         ${NEO4J_AUTH%%/*} / ${NEO4J_AUTH#*/}"
