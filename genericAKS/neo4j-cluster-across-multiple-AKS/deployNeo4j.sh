#!/usr/bin/env bash

set -e

NEO4J_NAMESPACE="neo4j"
HELM_CHART_VERSION="5.26.0"
REGIONS=("eastus" "westus2" "centralus")

usage() {
  echo "Usage: $0 [undeploy|redeploy]"
  echo "  undeploy - Remove Neo4j deployments and PVCs only"
  echo "  redeploy - Remove and reinstall Neo4j deployments"
  exit 1
}

if [ $# -ne 1 ]; then
  usage
fi

ACTION="$1"

if [[ "$ACTION" != "undeploy" && "$ACTION" != "redeploy" ]]; then
  usage
fi

for region in "${REGIONS[@]}"; do
  pvc_name="data-neo4j-${region}-0"

  echo "************** Processing $region deployment..."
  kubectl config use-context neo4j-aks-${region}

  echo "Uninstalling helm release neo4j-${region}..."
  helm uninstall neo4j-${region} --namespace "$NEO4J_NAMESPACE" || true

  echo "Deleting PVC $pvc_name..."
  kubectl delete pvc "$pvc_name" -n "$NEO4J_NAMESPACE" --wait=false || true

  if [ "$ACTION" == "redeploy" ]; then
    echo "Waiting for PVC deletion..."
    kubectl wait --for=delete pvc/"$pvc_name" -n "$NEO4J_NAMESPACE" --timeout=60s 2>/dev/null || true
    
    echo "Installing neo4j-${region}..."
    helm install neo4j-${region} neo4j/neo4j \
      --namespace "$NEO4J_NAMESPACE" \
      --version "$HELM_CHART_VERSION" \
      --values ./yaml/values-${region}.yaml
  fi

  echo "************** Completed $region"
done

echo ""
if [ "$ACTION" == "undeploy" ]; then
  echo "All regions undeployed."
else
  echo "All regions redeployed."
fi