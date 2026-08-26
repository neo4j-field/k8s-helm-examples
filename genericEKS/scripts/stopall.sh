#!/usr/bin/env bash
#
# Tear down the hybrid GDS cluster on EKS.
#
# Run from anywhere; the script cd's to the genericEKS root itself.
#   ./scripts/stopall.sh [OPTIONS]
#
# Nothing is deleted unless at least one option is given -- with no
# arguments this just prints usage and exits.
#
# Automatically finds and reads deployed-<cluster>-<release>/deployment.env
# (written by startall.sh) to determine the cluster name, Helm release
# prefix, and GDS count actually used, so a deployment made with
# --cluster-name/--release-name/--gds-count on startall.sh is torn down
# correctly without repeating those flags here. If exactly one deployed-*/
# directory exists, it's used automatically. If more than one exists, pass
# --cluster-name/--release-name (below) to pick one -- this script will
# refuse to guess. Falls back to the defaults below (jhair-cluster/neo4j/2)
# if no deployed-*/ directory exists at all.
#
# Options (independent and combinable):
#   --uninstall-neo4j    Uninstall the Neo4j Helm releases; delete their
#                        data/transactions PVCs and PVs (a full wipe by
#                        design -- reclaimPolicy: Retain does NOT protect
#                        these, see CLAUDE.md); delete leftover *-cleanup
#                        pods.
#   --undeploy-lb        Delete all 3 load balancers (core + 2 GDS).
#   --all                Delete the nodegroup, the EKS cluster (and its
#                        CloudFormation stacks), and the shared EFS
#                        filesystem/mount targets/security group.
#
#                        Implies --undeploy-lb: the AWS Load Balancer
#                        Controller pod (which deletes the real AWS NLB when
#                        its k8s Service is deleted) is destroyed along with
#                        the cluster, so the LBs must be deleted first or
#                        they're permanently orphaned in AWS.
#
#                        Also implies --uninstall-neo4j: the data/
#                        transactions EBS volumes use reclaimPolicy: Retain,
#                        so if the cluster is gone before their PVCs are
#                        deleted, nothing is left to ever delete those
#                        volumes and they bill forever.
#   -h, --help           Show this help and exit.
#
# Stops immediately on any command failure (set -e/-o pipefail), including
# failures inside a `cmd | awk ...` pipeline.
set -euo pipefail
trap 'echo "ERROR: command failed (exit $?) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
# aws-cli v2 pipes JSON responses through a pager (less) by default when run
# in an interactive terminal, which silently hangs this script waiting for a
# keypress on any of the many `aws ...` calls below that don't set --output.
export AWS_PAGER=""

# ---------------------------------------------------------------------------
# Option selection
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: stopall.sh [OPTIONS]

Tear down the hybrid GDS Neo4j cluster on EKS. Nothing is deleted unless at
least one option is given.

Automatically finds and reads a deployed-<cluster>-<release>/deployment.env
(written by startall.sh) for the cluster name, release prefix, and GDS
count actually deployed. If exactly one deployed-*/ directory exists, it's
used automatically; if more than one exists, use --cluster-name/
--release-name to pick one (this script refuses to guess). Falls back to
jhair-cluster/neo4j/2 if no deployed-*/ directory exists at all.

Options (independent and combinable):
  --uninstall-neo4j    Uninstall the Neo4j Helm releases; delete their
                       data/transactions PVCs and PVs (a full wipe -- see
                       CLAUDE.md).
  --undeploy-lb        Delete the core load balancer and however many GDS
                       load balancers were actually deployed (0-2).
  --all                Delete the nodegroup, the EKS cluster, and the shared
                       EFS filesystem. Implies --undeploy-lb and
                       --uninstall-neo4j (see script header comment for why:
                       skipping either orphans real, still-billing AWS
                       resources once the cluster is gone).
  --cluster-name NAME  Select which deployed-*/ directory to use by
                       cluster name (see above).
  --release-name PREFIX  Select which deployed-*/ directory to use by
                       release prefix (see above).
  -h, --help           Show this help and exit.
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

UNINSTALL_NEO4J=false
UNDEPLOY_LB=false
REMOVE_CLUSTER=false
CLUSTER_NAME_ARG=""
RELEASE_PREFIX_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall-neo4j) UNINSTALL_NEO4J=true; shift ;;
    --undeploy-lb) UNDEPLOY_LB=true; shift ;;
    --all) REMOVE_CLUSTER=true; shift ;;
    --cluster-name)
      if [[ -z "${2:-}" ]]; then echo "ERROR: --cluster-name requires a value" >&2; usage; exit 1; fi
      CLUSTER_NAME_ARG="$2"; shift 2 ;;
    --release-name)
      if [[ -z "${2:-}" ]]; then echo "ERROR: --release-name requires a value" >&2; usage; exit 1; fi
      RELEASE_PREFIX_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "${REMOVE_CLUSTER}" == "true" ]]; then
  if [[ "${UNDEPLOY_LB}" == "false" ]]; then
    echo "--all implies --undeploy-lb (avoids orphaning the AWS NLBs)."
  fi
  if [[ "${UNINSTALL_NEO4J}" == "false" ]]; then
    echo "--all implies --uninstall-neo4j (avoids orphaning the data/transactions EBS volumes)."
  fi
  UNDEPLOY_LB=true
  UNINSTALL_NEO4J=true
fi

# ---------------------------------------------------------------------------
# Configuration (defaults; overridden below by deployed/deployment.env if
# startall.sh has been run -- see that file's header comment)
# ---------------------------------------------------------------------------
CLUSTER_CONFIG="eks_create_cluster-jhair.yaml"
EKS_CLUSTER_NAME="jhair-cluster"   # metadata.name in CLUSTER_CONFIG
EKS_REGION="us-east-2"             # metadata.region in CLUSTER_CONFIG
NODEGROUP="neo4j-ng"
NAMESPACE="neo4j-ns"
RELEASE_PREFIX="neo4j"

CORE_COUNT=3
GDS_COUNT=2   # conservative fallback (max footprint) if deployment.env is missing -- see below

CORE_LB="lb-neo4j-core.yaml"
GDS_LBS_ALL=(lb1-gds.yaml lb2-gds.yaml)

# ---------------------------------------------------------------------------
# cd to the genericEKS root (parent of this script's dir) so relative paths work
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# ---------------------------------------------------------------------------
# Find and pick up what startall.sh actually deployed (cluster name, release
# prefix, GDS count, etc.), recorded in deployed-<cluster>-<release>/
# deployment.env. Without this, --cluster-name/--release-name/--gds-count on
# startall.sh would have no way to be torn down correctly. Multiple such
# directories can exist side by side (one per cluster+release combination
# startall.sh has ever deployed here) -- narrow with --cluster-name/
# --release-name when more than one matches; this script refuses to guess
# rather than risk tearing down the wrong one. If nothing matches at all
# (e.g. deployed-*/ was cleaned, or startall.sh was never run from this
# checkout), fall back to the hardcoded defaults above, applying
# --cluster-name/--release-name if given -- GDS_COUNT stays at the max (2)
# in that case since over-attempting cleanup is harmless
# (--ignore-not-found everywhere) but under-attempting it can orphan real
# resources.
# ---------------------------------------------------------------------------
if [[ -n "${CLUSTER_NAME_ARG}" && -n "${RELEASE_PREFIX_ARG}" ]]; then
  GLOB_PATTERN="deployed-${CLUSTER_NAME_ARG}-${RELEASE_PREFIX_ARG}"
elif [[ -n "${CLUSTER_NAME_ARG}" ]]; then
  GLOB_PATTERN="deployed-${CLUSTER_NAME_ARG}-*"
elif [[ -n "${RELEASE_PREFIX_ARG}" ]]; then
  GLOB_PATTERN="deployed-*-${RELEASE_PREFIX_ARG}"
else
  GLOB_PATTERN="deployed-*"
fi

shopt -s nullglob
MATCHES=()
for d in ${GLOB_PATTERN}; do
  [[ -f "${d}/deployment.env" ]] && MATCHES+=("${d}")
done
shopt -u nullglob

if [[ "${#MATCHES[@]}" -eq 1 ]]; then
  DEPLOYMENT_STATE_FILE="${MATCHES[0]}/deployment.env"
  echo "Using deployment parameters from ${DEPLOYMENT_STATE_FILE}."
  # shellcheck disable=SC1090
  source "${DEPLOYMENT_STATE_FILE}"
elif [[ "${#MATCHES[@]}" -gt 1 ]]; then
  echo "ERROR: multiple matching deployments found; pass --cluster-name and/or" \
       "--release-name to pick one:" >&2
  printf '  %s\n' "${MATCHES[@]}" >&2
  exit 1
else
  [[ -n "${CLUSTER_NAME_ARG}" ]] && EKS_CLUSTER_NAME="${CLUSTER_NAME_ARG}"
  [[ -n "${RELEASE_PREFIX_ARG}" ]] && RELEASE_PREFIX="${RELEASE_PREFIX_ARG}"
  echo "No matching deployed-*/deployment.env found; using cluster=${EKS_CLUSTER_NAME}," \
       "release-prefix=${RELEASE_PREFIX}, gds-count=${GDS_COUNT}."
fi
GDS_LBS=("${GDS_LBS_ALL[@]:0:GDS_COUNT}")

# eksctl reads the cluster name to operate on from CLUSTER_CONFIG's own
# metadata.name, not from EKS_CLUSTER_NAME -- if a custom cluster name was
# deployed, write a temp copy with metadata.name substituted (same trick
# startall.sh uses), or eksctl's nodegroup deletion below would silently
# target/look for the wrong cluster (jhair-cluster).
if [[ "${EKS_CLUSTER_NAME}" != "jhair-cluster" ]]; then
  SCRATCH_DIR="deployed-${EKS_CLUSTER_NAME}-${RELEASE_PREFIX}"
  mkdir -p "${SCRATCH_DIR}"
  TMP_CLUSTER_CONFIG="$(mktemp "${SCRATCH_DIR}/eks-cluster-config.XXXXXX.yaml")"
  trap 'rm -f "${TMP_CLUSTER_CONFIG}"' EXIT
  sed "s/^  name: .*/  name: ${EKS_CLUSTER_NAME}/" "${CLUSTER_CONFIG}" > "${TMP_CLUSTER_CONFIG}"
  CLUSTER_CONFIG="${TMP_CLUSTER_CONFIG}"
fi

# ---------------------------------------------------------------------------
# 0. AWS auth + kubectl context (this box is also used against AKS clusters,
#    so kubectl's current-context may be pointed elsewhere)
# ---------------------------------------------------------------------------
echo "Checking AWS SSO session..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS SSO session expired or missing; running 'aws sso login'..."
  aws sso login
fi

echo "Pointing kubectl at EKS cluster (${EKS_CLUSTER_NAME}, ${EKS_REGION})..."
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}"

CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "${CURRENT_CONTEXT}" != *"${EKS_CLUSTER_NAME}"* ]]; then
  echo "ERROR: kubectl context is '${CURRENT_CONTEXT}', expected it to reference '${EKS_CLUSTER_NAME}'. Aborting." >&2
  exit 1
fi
echo "kubectl context confirmed: ${CURRENT_CONTEXT}"

# ---------------------------------------------------------------------------
# 1. Uninstall Neo4j releases (--uninstall-neo4j)
# ---------------------------------------------------------------------------
if [[ "${UNINSTALL_NEO4J}" == "true" ]]; then
  CORE_RELEASES=$(for i in $(seq 1 "${CORE_COUNT}"); do echo -n "${RELEASE_PREFIX}-${i} "; done)
  GDS_RELEASES=$(for i in $(seq 1 "${GDS_COUNT}"); do echo -n "${RELEASE_PREFIX}-gds-${i} "; done)

  echo "Uninstalling Neo4j releases..."
  # shellcheck disable=SC2086
  helm uninstall ${CORE_RELEASES} ${GDS_RELEASES} --namespace "${NAMESPACE}" --ignore-not-found

  echo "Sleeping 30 seconds for pods to terminate..."
  sleep 30

  # -------------------------------------------------------------------------
  # 1b. Delete the data/transactions PVCs (and their PVs) for each
  #     uninstalled release. These use reclaimPolicy: Retain (see
  #     CLAUDE.md), so deleting the PVC alone leaves the PV behind in a
  #     Released state -- delete both explicitly for a full wipe. Does NOT
  #     touch pvc-efs-dynamic: that's the shared import/backup volume, not
  #     tied to any single release.
  # -------------------------------------------------------------------------
  echo "Deleting data/transactions PVCs and PVs for all releases..."
  # shellcheck disable=SC2086
  for release in ${CORE_RELEASES} ${GDS_RELEASES}; do
    for prefix in data transactions; do
      PVC_NAME="${prefix}-${release}-0"
      if kubectl get pvc "${PVC_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        PV_NAME="$(kubectl get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeName}')"
        kubectl delete pvc "${PVC_NAME}" -n "${NAMESPACE}"
        if [[ -n "${PV_NAME}" ]]; then
          kubectl delete pv "${PV_NAME}" --ignore-not-found
        fi
      else
        echo "PVC ${PVC_NAME} not found, skipping."
      fi
    done
  done

  # -------------------------------------------------------------------------
  # 1c. Clean up leftover cleanup jobs/pods (the chart doesn't always clear them)
  # -------------------------------------------------------------------------
  echo "Deleting leftover core cleanup pods..."
  CORE_CLEANUP=$(kubectl get pods -n "${NAMESPACE}" -o=name | awk -v p="${RELEASE_PREFIX}" '$0 ~ p"-[0-9]+-cleanup"{print $1}')
  if [[ -n "${CORE_CLEANUP}" ]]; then
    # shellcheck disable=SC2086
    kubectl delete -n "${NAMESPACE}" ${CORE_CLEANUP}
  else
    echo "None found."
  fi

  echo "Deleting leftover GDS cleanup pods..."
  GDS_CLEANUP=$(kubectl get pods -n "${NAMESPACE}" -o=name | awk -v p="${RELEASE_PREFIX}" '$0 ~ p"-gds-[0-9]+-cleanup"{print $1}')
  if [[ -n "${GDS_CLEANUP}" ]]; then
    # shellcheck disable=SC2086
    kubectl delete -n "${NAMESPACE}" ${GDS_CLEANUP}
  else
    echo "None found."
  fi
else
  echo "Skipping Neo4j uninstall (pass --uninstall-neo4j to uninstall it)."
fi

# ---------------------------------------------------------------------------
# 2. Load balancers (--undeploy-lb)
# ---------------------------------------------------------------------------
if [[ "${UNDEPLOY_LB}" == "true" ]]; then
  echo "Deleting load balancers..."
  kubectl delete -f "${CORE_LB}" --wait=false --ignore-not-found
  for lb in "${GDS_LBS[@]}"; do
    kubectl delete -f "${lb}" --wait=false --ignore-not-found
  done

  if [[ "${REMOVE_CLUSTER}" == "true" ]]; then
    echo "Sleeping 30 seconds so the AWS Load Balancer Controller can start" \
         "deleting the real NLBs before the nodegroup that runs it is destroyed..."
    sleep 30
  fi
else
  echo "Skipping load balancer deletion (pass --undeploy-lb to remove them)."
fi

# ---------------------------------------------------------------------------
# 3. Nodegroup + cluster + EFS (--all)
# ---------------------------------------------------------------------------
if [[ "${REMOVE_CLUSTER}" == "true" ]]; then
  echo "Deleting nodegroup (${NODEGROUP})..."
  # --disable-eviction: when ${NODEGROUP} is the cluster's only nodegroup, eksctl
  # cordons every node before draining any of them, so kube-system deployments
  # running 2 replicas behind a PodDisruptionBudget (coredns, ebs-csi-controller,
  # metrics-server) can never reschedule their 2nd replica and permanently block
  # eviction ("N pods are unevictable"). Bypassing PDBs here is safe since these
  # pods are being destroyed along with the nodegroup regardless.
  if ! eksctl delete nodegroup --config-file="${CLUSTER_CONFIG}" --include="${NODEGROUP}" --disable-eviction --approve; then
    # eksctl has a known race here: it issues DeleteNodegroup, then does a
    # follow-up status check that can hit the EKS API just after deletion has
    # already completed, and reports the resulting 404 as a failure instead of
    # confirmation of success. Verify against the API before treating this as
    # a real error.
    echo "eksctl reported an error deleting the nodegroup; verifying against the EKS API..."
    if aws eks describe-nodegroup --cluster-name "${EKS_CLUSTER_NAME}" --nodegroup-name "${NODEGROUP}" --region "${EKS_REGION}" >/dev/null 2>&1; then
      echo "ERROR: nodegroup ${NODEGROUP} still exists; deletion genuinely failed." >&2
      exit 1
    else
      echo "Nodegroup ${NODEGROUP} no longer exists -- eksctl's error was a false alarm. Continuing."
    fi
  fi

  delete_stack_with_force_fallback() {
    local stack_name="$1"
    aws cloudformation delete-stack --region "${EKS_REGION}" --stack-name "${stack_name}"
    if ! aws cloudformation wait stack-delete-complete --region "${EKS_REGION}" --stack-name "${stack_name}"; then
      echo "Stack ${stack_name} didn't delete cleanly (likely DELETE_FAILED on a resource" \
           "with a dependency CloudFormation doesn't know about); retrying with" \
           "--deletion-mode FORCE_DELETE_STACK..."
      aws cloudformation delete-stack --region "${EKS_REGION}" --stack-name "${stack_name}" \
        --deletion-mode FORCE_DELETE_STACK
      aws cloudformation wait stack-delete-complete --region "${EKS_REGION}" --stack-name "${stack_name}"
    fi
    echo "Stack ${stack_name} deleted."
  }

  # EFS filesystem/mount targets/security group cleanup (root-cause fix).
  # startall.sh provisions these directly via the AWS CLI, so CloudFormation
  # has no idea they exist. Left behind, their mount-target ENIs sit in the
  # node subnets and block the cluster stack's Subnets from ever deleting
  # ("has dependencies and cannot be deleted"), leaving the whole stack stuck
  # DELETE_FAILED. Clean these up BEFORE attempting cluster deletion so that
  # failure mode doesn't happen in the first place.
  EFS_CREATION_TOKEN="${EKS_CLUSTER_NAME}-efs"
  echo "Cleaning up EFS filesystem (creation token ${EFS_CREATION_TOKEN})..."
  EFS_ID="$(aws efs describe-file-systems --region "${EKS_REGION}" \
    --query "FileSystems[?CreationToken=='${EFS_CREATION_TOKEN}'].FileSystemId | [0]" --output text)"
  if [[ "${EFS_ID}" != "None" && -n "${EFS_ID}" ]]; then
    MT_IDS="$(aws efs describe-mount-targets --region "${EKS_REGION}" --file-system-id "${EFS_ID}" \
      --query 'MountTargets[].MountTargetId' --output text)"
    for mt in ${MT_IDS}; do
      echo "Deleting mount target ${mt}..."
      aws efs delete-mount-target --region "${EKS_REGION}" --mount-target-id "${mt}"
    done
    if [[ -n "${MT_IDS}" ]]; then
      echo "Waiting for mount targets to clear..."
      for _ in $(seq 1 20); do
        MT_COUNT="$(aws efs describe-mount-targets --region "${EKS_REGION}" --file-system-id "${EFS_ID}" \
          --query 'length(MountTargets)' --output text)"
        [[ "${MT_COUNT}" == "0" ]] && break
        sleep 10
      done
    fi
    echo "Deleting EFS filesystem ${EFS_ID}..."
    aws efs delete-file-system --region "${EKS_REGION}" --file-system-id "${EFS_ID}"
  else
    echo "No EFS filesystem found for creation token ${EFS_CREATION_TOKEN}; skipping."
  fi

  EFS_SG_NAME="${EKS_CLUSTER_NAME}-efs-sg"
  EFS_SG_ID="$(aws ec2 describe-security-groups --region "${EKS_REGION}" \
    --filters "Name=group-name,Values=${EFS_SG_NAME}" --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "${EFS_SG_ID}" != "None" && -n "${EFS_SG_ID}" ]]; then
    echo "Deleting EFS security group ${EFS_SG_ID}..."
    aws ec2 delete-security-group --region "${EKS_REGION}" --group-id "${EFS_SG_ID}"
  else
    echo "No EFS security group (${EFS_SG_NAME}) found; skipping."
  fi

  echo "Deleting EKS cluster (${EKS_CLUSTER_NAME})..."
  if ! eksctl delete cluster --region="${EKS_REGION}" --name="${EKS_CLUSTER_NAME}"; then
    echo "eksctl couldn't find the cluster via the EKS API; falling back to deleting" \
         "its CloudFormation stacks directly (handles a cluster deleted out-of-band)."

    # The cluster stack exports values (e.g. ClusterSecurityGroupId) consumed by
    # its nodegroup stacks, so any leftover nodegroup stack (not just the one
    # ${NODEGROUP} names above -- there may be orphans from older deployments)
    # must be deleted first or the cluster stack delete is silently refused.
    NODEGROUP_STACKS=$(aws cloudformation list-stacks --region "${EKS_REGION}" \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${EKS_CLUSTER_NAME}-nodegroup-') && StackStatus!='DELETE_COMPLETE'].StackName" \
      --output text)
    if [[ -n "${NODEGROUP_STACKS}" ]]; then
      for ng_stack in ${NODEGROUP_STACKS}; do
        echo "Deleting leftover nodegroup stack ${ng_stack}..."
        delete_stack_with_force_fallback "${ng_stack}"
      done
    fi

    delete_stack_with_force_fallback "eksctl-${EKS_CLUSTER_NAME}-cluster"
  fi

  # The cluster is gone; a deployed-*/ directory found via the discovery
  # logic above (as opposed to a manual --cluster-name/--release-name
  # override with no matching directory) is now stale and would otherwise
  # sit around as an ambiguous match for a future stopall.sh run.
  if [[ "${#MATCHES[@]}" -eq 1 ]]; then
    echo "Removing ${MATCHES[0]} (deployment torn down)..."
    rm -rf "${MATCHES[0]}"
  fi
else
  echo "Skipping nodegroup/cluster/EFS removal (pass --all to delete them)."
fi

echo "-------------------------------------------------------"
echo "Done. Ran:" \
  "$([[ "${UNINSTALL_NEO4J}" == "true" ]] && echo -n "--uninstall-neo4j ")" \
  "$([[ "${UNDEPLOY_LB}" == "true" ]] && echo -n "--undeploy-lb ")" \
  "$([[ "${REMOVE_CLUSTER}" == "true" ]] && echo -n "--all")"
echo "-------------------------------------------------------"
