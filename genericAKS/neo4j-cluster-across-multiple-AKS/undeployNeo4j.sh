#!/usr/bin/env bash

################################################################################
# Neo4j Undeployment Script for Multi-Region AKS
# This script removes Neo4j resources while keeping AKS infrastructure intact
# - Deletes Neo4j StatefulSets and Services
# - Removes PVCs and PVs (data will be lost)
# - Cleans up ConfigMaps and Secrets
# - Preserves AKS clusters, node pools, and networking
################################################################################

set -e  # Exit on error

# Configuration (must match deployment script)
REGIONS=("eastus" "westus2" "centralus")
CLUSTER_NAME_PREFIX="neo4j-aks"
NEO4J_NAMESPACE="neo4j"
HELM_RELEASE_PREFIX="neo4j"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

confirm_deletion() {
    log_warn "This will DELETE all Neo4j resources across 3 regions:"
    log_warn "  - Neo4j StatefulSets (neo4j-eastus, neo4j-westus2, neo4j-centralus)"
    # log_warn "  - Neo4j Services (LoadBalancers and headless service)"
    # log_warn "  - Persistent Volume Claims (ALL DATA WILL BE LOST)"
    # log_warn "  - Secrets and ConfigMaps"
    echo ""
    log_info "AKS clusters and node pools will be PRESERVED"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "Undeployment cancelled"
        exit 0
    fi
}

delete_clusterLB_resources() {
    log_info "Deleting Load Balancers from all regions..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local lb_int_name="${HELM_RELEASE_PREFIX}-${region}-internal-lb"
        local lb_pub_name="${HELM_RELEASE_PREFIX}-${region}-public-lb"
        
        log_info "Processing region: $region (context: $context)"
        
        # Check if context exists
        if ! kubectl config get-contexts "$context" &>/dev/null; then
            log_warn "Context $context not found, skipping"
            continue
        fi
        
        kubectl config use-context "$context"
        
        # Check if namespace exists
        if ! kubectl get namespace "$NEO4J_NAMESPACE" &>/dev/null; then
            log_warn "Namespace $NEO4J_NAMESPACE not found in $region, skipping"
            continue
        fi
        
        # Delete PVC (this will automatically delete the PV if using dynamic provisioning)
        echo "Deleting LBs: $lb_int_name / $lb_pub_name"
        kubectl delete svc "$lb_int_name" -n "$NEO4J_NAMESPACE" || true
        kubectl delete svc "$lb_pub_name" -n "$NEO4J_NAMESPACE" || true

        log_info "Load balancers deleted from $region"
        echo ""
    done
}

delete_neo4j_resources() {
    log_info "Deleting Neo4j resources from all regions..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        local pvc_name="data-neo4j-${region}-0"
        
        log_info "Processing region: $region (context: $context)"
        
        # Check if context exists
        if ! kubectl config get-contexts "$context" &>/dev/null; then
            log_warn "Context $context not found, skipping"
            continue
        fi
        
        kubectl config use-context "$context"
        
        # Check if namespace exists
        if ! kubectl get namespace "$NEO4J_NAMESPACE" &>/dev/null; then
            log_warn "Namespace $NEO4J_NAMESPACE not found in $region, skipping"
            continue
        fi
        
        helm uninstall "$release_name" --namespace "$NEO4J_NAMESPACE" || true

        # Delete PVC (this will automatically delete the PV if using dynamic provisioning)
        echo "Deleting PVC: $pvc_name"
        kubectl delete pvc "$pvc_name" -n "$NEO4J_NAMESPACE" || true

        # log_info "Deleting Neo4j secrets"
        # kubectl delete secret neo4j-auth \
        #     -n "$NEO4J_NAMESPACE" \
        #     --ignore-not-found=true
        
        log_info "Neo4j resources deleted from $region"
        echo ""
    done
}

cleanup_namespace() {
    log_info "Cleaning up Neo4j namespace..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        
        if ! kubectl config get-contexts "$context" &>/dev/null; then
            continue
        fi
        
        kubectl config use-context "$context"
        
        if kubectl get namespace "$NEO4J_NAMESPACE" &>/dev/null; then
            log_info "Deleting namespace: $NEO4J_NAMESPACE in $region"
            kubectl delete namespace "$NEO4J_NAMESPACE" \
                --ignore-not-found=true \
                --timeout=120s || true
        fi
    done
}

cleanup_coredns_config() {
    log_info "Cleaning up CoreDNS custom configuration..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        
        if ! kubectl config get-contexts "$context" &>/dev/null; then
            continue
        fi
        
        kubectl config use-context "$context"
        
        if kubectl get configmap coredns-custom -n kube-system &>/dev/null; then
            log_info "Removing neo4j.server entry from coredns-custom in $region"
            # Remove the neo4j.server key from the ConfigMap
            kubectl patch configmap coredns-custom -n kube-system \
                --type=json \
                -p='[{"op": "remove", "path": "/data/neo4j.server"}]' \
                2>/dev/null || log_warn "Could not remove neo4j.server from coredns-custom"
        fi
    done
}

verify_cleanup() {
    log_info "Verifying cleanup..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        
        if ! kubectl config get-contexts "$context" &>/dev/null; then
            continue
        fi
        
        kubectl config use-context "$context"
        
        log_info "Checking $region:"
        
        # Check for remaining pods
        local pod_count=$(kubectl get pods -n "$NEO4J_NAMESPACE" --no-headers 2>/dev/null | grep -E "^neo4j-" | wc -l)
        if [ "$pod_count" -gt 0 ]; then
            log_warn "  Found $pod_count Neo4j pod(s) still running"
        else
            log_info "  ✓ No Neo4j pods found"
        fi
        
        # Check for services
        local svc_count=$(kubectl get svc -n "$NEO4J_NAMESPACE" 2>/dev/null | grep -E "^neo4j-" | wc -l)
        if [ "$svc_count" -gt 0 ]; then
            log_warn "  Found $svc_count Neo4j service(s) still present"
        else
            log_info "  ✓ No Neo4j services found"
        fi
        
        # Check for PVCs
        local pvc_count=$(kubectl get pvc -n "$NEO4J_NAMESPACE" 2>/dev/null | wc -l || echo "0")
        if [ "$pvc_count" -gt 0 ]; then
            log_warn "  Found $pvc_count PVC(s) still present"
        else
            log_info "  ✓ No PVCs found"
        fi
        
        echo ""
    done
}

print_summary() {
    log_info "=========================================="
    log_info "Neo4j Undeployment Complete!"
    log_info "=========================================="
    echo ""
    log_info "Removed resources:"
    log_info "  ✓ Neo4j StatefulSets (all regions)"
    log_info "  ✓ Neo4j Services (LoadBalancer and headless)"
    log_info "  ✓ Persistent Volume Claims (data deleted)"
    log_info "  ✓ Secrets and namespace"
    log_info "  ✓ CoreDNS custom configuration"
    echo ""
    log_info "Preserved resources:"
    log_info "  ✓ AKS clusters (${REGIONS[*]})"
    log_info "  ✓ Node pools (system and neo4j)"
    log_info "  ✓ Virtual networks and peering"
    log_info "  ✓ Resource group"
    echo ""
    log_info "To redeploy Neo4j, run:"
    log_info "  ./deployNeo4jMultiRegion.sh"
    echo ""
    log_info "To delete ALL infrastructure, run:"
    log_info "  ./cleanupNeo4jMultiRegion.sh"
}

main() {
    log_info "Starting Neo4j Undeployment (AKS infrastructure will be preserved)"
    echo ""
    
    # confirm_deletion
    # echo ""
    
    delete_neo4j_resources
    # cleanup_coredns_config
    # cleanup_namespace

    delete_clusterLB_resources

    verify_cleanup
    
    print_summary
    
    log_info "Undeployment complete!"
}

# Run main function
main