#!/bin/bash

################################################################################
# Multi-Region Neo4j Cluster Cleanup Script
# This script removes all resources created by the deployment script
################################################################################

set -e

# Configuration (must match deployment script)
RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")
CLUSTER_NAME_PREFIX="neo4j-aks"

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
    log_warn "This will delete ALL resources in resource group: $RESOURCE_GROUP"
    log_warn "Including:"
    log_warn "  - 3 AKS clusters"
    log_warn "  - 3 Virtual Networks"
    log_warn "  - Azure Container Registry"
    log_warn "  - All Neo4j data"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
}

delete_aks_clusters() {
    log_info "Deleting AKS clusters..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        
        if az aks show --name "$cluster_name" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
            log_info "Deleting AKS cluster: $cluster_name"
            az aks delete \
                --name "$cluster_name" \
                --resource-group "$RESOURCE_GROUP" \
                --yes \
                --no-wait
        else
            log_warn "AKS cluster $cluster_name not found, skipping"
        fi
    done
    
    log_info "Waiting for AKS clusters to be deleted (this may take 10-15 minutes)..."
    sleep 60
}

delete_resource_group() {
    log_info "Deleting resource group: $RESOURCE_GROUP"
    
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        az group delete \
            --name "$RESOURCE_GROUP" \
            --yes \
            --no-wait
        
        log_info "Resource group deletion initiated"
        log_info "All resources will be deleted in the background"
    else
        log_warn "Resource group $RESOURCE_GROUP not found"
    fi
}

cleanup_kubectl_contexts() {
    log_info "Cleaning up kubectl contexts..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        
        if kubectl config get-contexts "$cluster_name" &>/dev/null; then
            kubectl config delete-context "$cluster_name" || true
            kubectl config delete-cluster "$cluster_name" || true
            log_info "Context $cluster_name removed"
        fi
    done
}

main() {
    log_info "Starting cleanup process..."
    echo ""
    
    confirm_deletion
    echo ""
    
    delete_aks_clusters
    delete_resource_group
    cleanup_kubectl_contexts
    
    echo ""
    log_info "=========================================="
    log_info "Cleanup Complete!"
    log_info "=========================================="
    log_info "All resources have been deleted or are being deleted."
    log_info "You can check the status in the Azure Portal."
}

main