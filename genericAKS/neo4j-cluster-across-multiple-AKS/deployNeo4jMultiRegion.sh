#!/usr/bin/env bash

################################################################################
# Multi-Region Neo4j Cluster Deployment on AKS using Dynamic DNS for RAFT
# This script deploys a 3-region Neo4j cluster using official Helm charts:
# - 3 Azure regions for geo-distribution
# - Standard Azure CNI (non-overlay) for routable pod IPs
# - VNet peering for cross-region pod communication
# - Neo4j Enterprise in cluster mode via Helm
# 
# RAFT COMMUNICATION STRATEGY (Dynamic DNS Registration):
# - Port 6000 (Discovery): LoadBalancer service (NAT-friendly)
# - Port 7000 (RAFT): Direct pod-to-pod via dynamic DNS
# - Init container registers pod IP in Azure Private DNS before Neo4j starts
# - RAFT advertised address uses predictable DNS name (e.g., neo4j-eastus-0-raft.neo4j.internal)
# - DNS record points to actual pod IP for direct routing
# 
# REQUIREMENTS:
# - Standard Azure CNI (--pod-subnet-id parameter)
# - NSG rules must allow port 7000 between pod subnets across regions
# - VNet peering must be configured (handled by this script)
# - Workload Identity enabled on AKS clusters (handled by this script)
################################################################################

set -e  # Exit on error

# Configuration
RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")
CLUSTER_NAME_PREFIX="neo4j-aks"
VNET_PREFIX="neo4j-vnet"
NEO4J_VERSION="5.26.0"
NEO4J_NAMESPACE="neo4j"
NEO4J_PASSWORD="ChangeThisPassword123!"
HELM_RELEASE_PREFIX="neo4j"
HELM_CHART_VERSION="5.26.16"
DNS_ZONE_NAME="neo4j.internal"

# Workload Identity Configuration
IDENTITY_NAME="neo4j-dns-updater-identity"
SERVICE_ACCOUNT_NAME="neo4j-dns-updater"

# AKS Configuration
AKS_SYSTEM_NODE_COUNT=3
AKS_SYSTEM_NODE_VM_SIZE="Standard_D4s_v3"
AKS_NEO4J_NODE_COUNT=4
AKS_NEO4J_NODE_VM_SIZE="Standard_E16as_v5"
K8S_VERSION="1.29"

# Network Configuration
VNET_ADDRESS_SPACE="10.0.0.0/8"
REGION_CIDRS=("10.1.0.0/16" "10.2.0.0/16" "10.3.0.0/16")
AKS_SUBNET_CIDRS=("10.1.0.0/20" "10.2.0.0/20" "10.3.0.0/20")
POD_SUBNET_CIDRS=("10.1.128.0/17" "10.2.128.0/17" "10.3.128.0/17")  # Upper half of region CIDR

# Global variables for identity
IDENTITY_CLIENT_ID=""
IDENTITY_PRINCIPAL_ID=""

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PS4='$(date "+%H:%M:%S") '

log_info() {
    echo -e "$(date "+%H:%M:%S")${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "$(date "+%H:%M:%S")${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "$(date "+%H:%M:%S")${RED}[ERROR]${NC} $1"
}

wait_for_deployment() {
    local resource_type=$1
    local resource_name=$2
    local resource_group=$3
    local max_attempts=60
    local attempt=0

    log_info "Waiting for $resource_type '$resource_name' to be ready..."
    
    while [ $attempt -lt $max_attempts ]; do
        if az $resource_type show --name "$resource_name" --resource-group "$resource_group" &>/dev/null; then
            log_info "$resource_type '$resource_name' is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 10
    done
    
    log_error "Timeout waiting for $resource_type '$resource_name'"
    return 1
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI not found. Please install it."
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install it."
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        log_error "Helm not found. Please install it: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Run 'az login'"
        exit 1
    fi
    
    log_info "All prerequisites met"
}

verify_nsg_rules() {
    log_info "Verifying NSG rules for cross-region RAFT connectivity..."
    log_info "Pod subnets (where Neo4j pods run):"
    for i in 0 1 2; do
        log_info "  ${REGIONS[$i]}: ${POD_SUBNET_CIDRS[$i]}"
    done
    log_info ""
    log_info "Required NSG rules:"
    log_info "  - Allow inbound TCP port 7000 from all pod subnets"
    log_info "  - Allow outbound TCP port 7000 to all pod subnets"
    log_info ""
    log_info "Configuring NSG rules automatically..."
    
    configure_nsg_rules
}

configure_nsg_rules() {
    log_info "Configuring NSG rules for Neo4j RAFT communication across pod subnets..."
    
    # Get NSG for each region and add rules
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        
        log_info "Getting node resource group for $cluster_name..."
        local node_rg=$(az aks show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --query nodeResourceGroup -o tsv 2>/dev/null)
        
        if [ -z "$node_rg" ]; then
            log_error "Could not get node resource group for $cluster_name"
            continue
        fi
        
        log_info "Finding NSG in resource group: $node_rg"
        local nsg_name=$(az network nsg list \
            --resource-group "$node_rg" \
            --query "[0].name" -o tsv 2>/dev/null)
        
        if [ -z "$nsg_name" ]; then
            log_error "Could not find NSG in $node_rg"
            continue
        fi
        
        log_info "Configuring NSG: $nsg_name for region $region"
        
        # Add inbound rules for RAFT from all pod subnets
        for j in 0 1 2; do
            local remote_region="${REGIONS[$j]}"
            local remote_cidr="${POD_SUBNET_CIDRS[$j]}"
            local rule_name="Allow-RAFT-Inbound-From-${remote_region}-Pods"
            local priority=$((1000 + j))
            
            # Check if rule already exists
            if az network nsg rule show \
                --resource-group "$node_rg" \
                --nsg-name "$nsg_name" \
                --name "$rule_name" &>/dev/null; then
                log_info "Inbound rule $rule_name already exists, skipping"
            else
                log_info "Creating inbound rule: $rule_name"
                az network nsg rule create \
                    --resource-group "$node_rg" \
                    --nsg-name "$nsg_name" \
                    --name "$rule_name" \
                    --priority "$priority" \
                    --direction Inbound \
                    --access Allow \
                    --protocol Tcp \
                    --source-address-prefixes "$remote_cidr" \
                    --source-port-ranges "*" \
                    --destination-address-prefixes "${POD_SUBNET_CIDRS[$i]}" \
                    --destination-port-ranges 7000 \
                    --description "Allow Neo4j RAFT from ${remote_region} pod subnet" \
                    --output none 2>/dev/null || log_warn "Rule creation failed or already exists"
            fi
        done
        
        # Add outbound rules for RAFT to all pod subnets
        for j in 0 1 2; do
            local remote_region="${REGIONS[$j]}"
            local remote_cidr="${POD_SUBNET_CIDRS[$j]}"
            local rule_name="Allow-RAFT-Outbound-To-${remote_region}-Pods"
            local priority=$((2000 + j))
            
            # Check if rule already exists
            if az network nsg rule show \
                --resource-group "$node_rg" \
                --nsg-name "$nsg_name" \
                --name "$rule_name" &>/dev/null; then
                log_info "Outbound rule $rule_name already exists, skipping"
            else
                log_info "Creating outbound rule: $rule_name"
                az network nsg rule create \
                    --resource-group "$node_rg" \
                    --nsg-name "$nsg_name" \
                    --name "$rule_name" \
                    --priority "$priority" \
                    --direction Outbound \
                    --access Allow \
                    --protocol Tcp \
                    --source-address-prefixes "${POD_SUBNET_CIDRS[$i]}" \
                    --source-port-ranges "*" \
                    --destination-address-prefixes "$remote_cidr" \
                    --destination-port-ranges 7000 \
                    --description "Allow Neo4j RAFT to ${remote_region} pod subnet" \
                    --output none 2>/dev/null || log_warn "Rule creation failed or already exists"
            fi
        done
        
        log_info "NSG rules configured for $region"
    done
    
    log_info "All NSG rules configured"
}

get_latest_k8s_version() {
    log_info "Detecting latest supported non-LTS Kubernetes version in ${REGIONS[0]}..."
    
    local versions=$(az aks get-versions \
        --location "${REGIONS[0]}" \
        --query "values[?isPreview==null].version" \
        --output tsv 2>/dev/null)
    
    local available_version=""
    for version in $versions; do
        if [[ ! "$version" =~ ^1\.28\. ]] && [[ ! "$version" =~ ^1\.30\. ]]; then
            available_version="$version"
            break
        fi
    done
    
    if [ -n "$available_version" ]; then
        K8S_VERSION="$available_version"
        log_info "Using Kubernetes version: $K8S_VERSION (non-LTS)"
    else
        log_warn "Could not auto-detect version, trying 1.29 explicitly"
        K8S_VERSION="1.29"
    fi
}

add_helm_repo() {
    log_info "Adding Neo4j Helm repository..."
    
    helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
    helm repo update
    
    log_info "Neo4j Helm repository added and updated"
}

create_resource_group() {
    log_info "Creating resource group: $RESOURCE_GROUP"
    
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        log_warn "Resource group $RESOURCE_GROUP already exists"
    else
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "${REGIONS[0]}" \
            --output none
        log_info "Resource group created"
    fi
}

create_vnets() {
    log_info "Creating virtual networks in each region..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local vnet_name="${VNET_PREFIX}-${region}"
        local aks_subnet="aks-subnet-${region}"
        local pod_subnet="pod-subnet-${region}"
        
        # Create VNet if it doesn't exist
        if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$vnet_name" &>/dev/null; then
            log_warn "VNet $vnet_name already exists, skipping creation"
        else
            log_info "Creating VNet: $vnet_name in $region"
            az network vnet create \
                --resource-group "$RESOURCE_GROUP" \
                --name "$vnet_name" \
                --location "$region" \
                --address-prefix "${REGION_CIDRS[$i]}" \
                --output none
        fi
        
        # Create AKS node subnet if it doesn't exist
        if az network vnet subnet show \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$vnet_name" \
            --name "$aks_subnet" &>/dev/null; then
            log_warn "AKS node subnet $aks_subnet already exists, skipping creation"
        else
            log_info "Creating AKS node subnet: $aks_subnet"
            az network vnet subnet create \
                --resource-group "$RESOURCE_GROUP" \
                --vnet-name "$vnet_name" \
                --name "$aks_subnet" \
                --address-prefixes "${AKS_SUBNET_CIDRS[$i]}" \
                --output none
        fi
        
        # Create Pod subnet with delegation if it doesn't exist
        if az network vnet subnet show \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$vnet_name" \
            --name "$pod_subnet" &>/dev/null; then
            log_warn "Pod subnet $pod_subnet already exists"
            
            # Check if delegation exists, add if missing
            local delegation=$(az network vnet subnet show \
                --resource-group "$RESOURCE_GROUP" \
                --vnet-name "$vnet_name" \
                --name "$pod_subnet" \
                --query "delegations[0].serviceName" -o tsv 2>/dev/null)
            
            if [ "$delegation" != "Microsoft.ContainerService/managedClusters" ]; then
                log_info "Adding delegation to existing pod subnet: $pod_subnet"
                az network vnet subnet update \
                    --resource-group "$RESOURCE_GROUP" \
                    --vnet-name "$vnet_name" \
                    --name "$pod_subnet" \
                    --delegations Microsoft.ContainerService/managedClusters \
                    --output none
            else
                log_info "Pod subnet $pod_subnet already has correct delegation"
            fi
        else
            log_info "Creating Pod subnet: $pod_subnet (Standard CNI with delegation)"
            az network vnet subnet create \
                --resource-group "$RESOURCE_GROUP" \
                --vnet-name "$vnet_name" \
                --name "$pod_subnet" \
                --address-prefixes "${POD_SUBNET_CIDRS[$i]}" \
                --delegations Microsoft.ContainerService/managedClusters \
                --output none
        fi
        
        log_info "VNet $vnet_name configured with node and pod subnets"
        sleep 2
    done
}

create_vnet_peering() {
    log_info "Creating VNet peering for cross-region communication (full mesh)..."
    
    for i in "${!REGIONS[@]}"; do
        for j in "${!REGIONS[@]}"; do
            if [ "$i" -eq "$j" ]; then
                continue
            fi
            
            local source_region="${REGIONS[$i]}"
            local target_region="${REGIONS[$j]}"
            local peering_name="peer-${source_region}-to-${target_region}"
            local source_vnet="${VNET_PREFIX}-${source_region}"
            local target_vnet="${VNET_PREFIX}-${target_region}"
            
            # Check if peering already exists
            if az network vnet peering show \
                --resource-group "$RESOURCE_GROUP" \
                --vnet-name "$source_vnet" \
                --name "$peering_name" &>/dev/null; then
                log_warn "Peering ${peering_name} already exists, skipping"
                continue
            fi
            
            log_info "Creating peering: ${source_region} -> ${target_region}"
            
            az network vnet peering create \
                --resource-group "$RESOURCE_GROUP" \
                --name "$peering_name" \
                --vnet-name "$source_vnet" \
                --remote-vnet "$target_vnet" \
                --allow-vnet-access \
                --allow-forwarded-traffic \
                --output none
            
            log_info "Peering ${peering_name} created"
        done
    done
    
    log_info "VNet peering completed (${#REGIONS[@]} regions, full mesh)"
    sleep 10
}

allocate_static_ips() {
    log_info "Allocating static PUBLIC IPs for public LoadBalancers..."
    
    declare -g -A STATIC_PUBLIC_IPS
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local public_ip_name="neo4j-public-lb-ip-${region}"
        
        local node_rg=$(az aks show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --query nodeResourceGroup -o tsv)

        # Check if public IP already exists
        if az network public-ip show \
            --resource-group "$node_rg" \
            --name "$public_ip_name" &>/dev/null; then
            
            local ip_address=$(az network public-ip show \
                --resource-group "$node_rg" \
                --name "$public_ip_name" \
                --query ipAddress -o tsv)
            
            STATIC_PUBLIC_IPS[$region]="$ip_address"
            log_warn "Public IP $public_ip_name already exists: $ip_address"
        else
            log_info "Allocating static public IP in $region: $public_ip_name"
            
            az network public-ip create \
                --resource-group "$node_rg" \
                --name "$public_ip_name" \
                --sku Standard \
                --allocation-method Static \
                --location "$region" \
                --output none
            
            local ip_address=$(az network public-ip show \
                --resource-group "$node_rg" \
                --name "$public_ip_name" \
                --query ipAddress -o tsv)
            
            STATIC_PUBLIC_IPS[$region]="$ip_address"
            log_info "Public static IP allocated for $region: $ip_address"
        fi
        sleep 3
    done
    
    log_info "All static public IPs allocated"
}

create_private_dns_zone() {
    log_info "Creating Azure Private DNS Zone for LoadBalancer DNS..."
    
    if az network private-dns zone show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DNS_ZONE_NAME" &>/dev/null; then
        log_warn "Private DNS Zone $DNS_ZONE_NAME already exists, skipping creation"
    else
        az network private-dns zone create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$DNS_ZONE_NAME" \
            --output none
        
        log_info "Private DNS Zone created: $DNS_ZONE_NAME"
    fi
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local vnet_name="${VNET_PREFIX}-${region}"
        local link_name="dns-link-${region}"
        
        log_info "Linking DNS zone to VNet: $vnet_name"
        
        if az network private-dns link vnet show \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$link_name" &>/dev/null; then
            log_warn "DNS link $link_name already exists, skipping"
            continue
        fi
        
        local vnet_id=$(az network vnet show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$vnet_name" \
            --query id -o tsv)
        
        az network private-dns link vnet create \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$link_name" \
            --virtual-network "$vnet_id" \
            --registration-enabled false \
            --output none
        
        log_info "DNS link created: $link_name"
        sleep 2
    done
    
    log_info "DNS zone linked to all VNets"
}

create_dns_records() {
    log_info "Creating DNS A records for LoadBalancer IPs..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local int_release_name="${HELM_RELEASE_PREFIX}-${region}-internal-lb"
        local pub_release_name="${HELM_RELEASE_PREFIX}-${region}-public-lb"
        
        kubectl config use-context "$context"
        
        # Get internal LoadBalancer IP
        log_info "Retrieving internal LoadBalancer IP for $int_release_name..."
        local internal_ip_address=""
        local attempts=0
        while [ -z "$internal_ip_address" ] && [ $attempts -lt 30 ]; do
            internal_ip_address=$(kubectl get svc "$int_release_name" -n "$NEO4J_NAMESPACE" \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            if [ -z "$internal_ip_address" ]; then
                attempts=$((attempts + 1))
                echo -n "."
                sleep 10
            fi
        done
        
        if [ -z "$internal_ip_address" ]; then
            log_error "Failed to retrieve internal LoadBalancer IP for $int_release_name"
            return 1
        fi
        
        log_info "Internal LoadBalancer IP for $region: $internal_ip_address"
        
        # Create/update DNS record for internal LB
        if az network private-dns record-set a show \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$int_release_name" &>/dev/null; then
            
            local existing_ip=$(az network private-dns record-set a show \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --name "$int_release_name" \
                --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null)
            
            if [ "$existing_ip" != "$internal_ip_address" ]; then
                az network private-dns record-set a remove-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$int_release_name" \
                    --ipv4-address "$existing_ip" \
                    --output none 2>/dev/null || true
                
                az network private-dns record-set a add-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$int_release_name" \
                    --ipv4-address "$internal_ip_address" \
                    --output none
                
                log_info "DNS A record updated for $int_release_name"
            fi
        else
            az network private-dns record-set a add-record \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --record-set-name "$int_release_name" \
                --ipv4-address "$internal_ip_address" \
                --output none
            
            log_info "DNS A record created for $int_release_name"
        fi
        
        # Public IP DNS record
        local pub_ip_address="${STATIC_PUBLIC_IPS[$region]}"
        
        if [ -z "$pub_ip_address" ]; then
            log_error "No public IP address found for region: $region"
            return 1
        fi
        
        log_info "Creating DNS record: ${pub_release_name}.${DNS_ZONE_NAME} -> $pub_ip_address"
        
        if az network private-dns record-set a show \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$pub_release_name" &>/dev/null; then
            
            local existing_ip=$(az network private-dns record-set a show \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --name "$pub_release_name" \
                --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null)
            
            if [ "$existing_ip" != "$pub_ip_address" ]; then
                az network private-dns record-set a remove-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$pub_release_name" \
                    --ipv4-address "$existing_ip" \
                    --output none 2>/dev/null || true
                
                az network private-dns record-set a add-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$pub_release_name" \
                    --ipv4-address "$pub_ip_address" \
                    --output none
                
                log_info "DNS A record updated for $pub_release_name"
            fi
        else
            az network private-dns record-set a add-record \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --record-set-name "$pub_release_name" \
                --ipv4-address "$pub_ip_address" \
                --output none
            
            log_info "DNS A record created for $pub_release_name"
        fi

        sleep 2
    done
    
    log_info "All DNS records created"
}

create_aks_clusters() {
    log_info "\nCreating AKS clusters with Standard Azure CNI (pod subnets)..."
    
    declare -A REGION_ZONES
    REGION_ZONES["eastus"]="1 2 3"
    REGION_ZONES["westus2"]="2"
    REGION_ZONES["centralus"]="1 2 3"
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local vnet_name="${VNET_PREFIX}-${region}"
        local subnet_name="aks-subnet-${region}"
        local pod_subnet_name="pod-subnet-${region}"
        local zones="${REGION_ZONES[$region]}"
        
        local subnet_id=$(az network vnet subnet show \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$vnet_name" \
            --name "$subnet_name" \
            --query id -o tsv)
        
        local pod_subnet_id=$(az network vnet subnet show \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$vnet_name" \
            --name "$pod_subnet_name" \
            --query id -o tsv)
        
        # Check if AKS cluster already exists
        if az aks show --resource-group "$RESOURCE_GROUP" --name "$cluster_name" &>/dev/null; then
            log_warn "AKS cluster $cluster_name already exists, skipping creation"
        else
            log_info "Creating AKS cluster: ${GREEN}$cluster_name in $region${NC}"
            log_info "Using Standard Azure CNI with dedicated pod subnet"
            
            local aks_cmd="az aks create \
                --resource-group $RESOURCE_GROUP \
                --name $cluster_name \
                --location $region \
                --kubernetes-version $K8S_VERSION \
                --nodepool-name systempool \
                --node-count $AKS_SYSTEM_NODE_COUNT \
                --node-vm-size $AKS_SYSTEM_NODE_VM_SIZE \
                --network-plugin azure \
                --vnet-subnet-id $subnet_id \
                --pod-subnet-id $pod_subnet_id \
                --service-cidr 10.$((i+10)).0.0/16 \
                --dns-service-ip 10.$((i+10)).0.10 \
                --enable-managed-identity \
                --enable-oidc-issuer \
                --enable-workload-identity \
                --node-osdisk-size 128 \
                --output none"
            
            if [ -n "$zones" ]; then
                aks_cmd="$aks_cmd --zones $zones"
            fi
            
            eval "$aks_cmd" 2>&1 | grep -v "docker_bridge_cidr" || true
            
            log_info "AKS cluster $cluster_name created with Standard CNI and Workload Identity"
            log_info "Pod subnet: ${POD_SUBNET_CIDRS[$i]} (routable across VNet peering)"
        fi
        
        wait_for_deployment "aks" "$cluster_name" "$RESOURCE_GROUP"
        
        log_info "Checking if Neo4j node pool exists in $cluster_name"
        if az aks nodepool show \
            --resource-group $RESOURCE_GROUP \
            --cluster-name $cluster_name \
            --name neo4jpool &>/dev/null; then
            log_warn "Neo4j node pool 'neo4jpool' already exists in $cluster_name, skipping creation"
        else
            log_info "Adding dedicated Neo4j node pool to $cluster_name"
            
            local nodepool_cmd="az aks nodepool add \
                --resource-group $RESOURCE_GROUP \
                --cluster-name $cluster_name \
                --name neo4jpool \
                --node-count $AKS_NEO4J_NODE_COUNT \
                --node-vm-size $AKS_NEO4J_NODE_VM_SIZE \
                --pod-subnet-id $pod_subnet_id \
                --labels workload=neo4j \
                --node-taints workload=neo4j:NoSchedule \
                --enable-cluster-autoscaler \
                --min-count 4 \
                --max-count 8 \
                --node-osdisk-size 256 \
                --output none"
            
            if [ -n "$zones" ]; then
                nodepool_cmd="$nodepool_cmd --zones $zones"
            fi
            
            eval "$nodepool_cmd" 2>&1 | grep -v "docker_bridge_cidr" || true
            log_info "Neo4j node pool added to $cluster_name"
        fi

        log_info "Getting credentials for $cluster_name"
        az aks get-credentials \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --context "$cluster_name" \
            --overwrite-existing
        
        log_info "Credentials for $cluster_name retrieved"

        log_info "Create $NEO4J_NAMESPACE namespace"
        kubectl create namespace "$NEO4J_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

        sleep 10
    done
}

################################################################################
# Workload Identity Setup Functions
################################################################################

enable_workload_identity_on_clusters() {
    log_info "Ensuring Workload Identity is enabled on AKS clusters..."
    
    for region in "${REGIONS[@]}"; do
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        
        log_info "Checking Workload Identity on $cluster_name..."
        
        local oidc_enabled=$(az aks show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --query "oidcIssuerProfile.enabled" -o tsv 2>/dev/null || echo "false")
        
        local wi_enabled=$(az aks show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --query "securityProfile.workloadIdentity.enabled" -o tsv 2>/dev/null || echo "false")
        
        if [ "$oidc_enabled" != "true" ] || [ "$wi_enabled" != "true" ]; then
            log_info "Enabling OIDC issuer and Workload Identity on $cluster_name..."
            az aks update \
                --resource-group "$RESOURCE_GROUP" \
                --name "$cluster_name" \
                --enable-oidc-issuer \
                --enable-workload-identity \
                --output none
            log_info "Workload Identity enabled on $cluster_name"
        else
            log_info "Workload Identity already enabled on $cluster_name"
        fi
    done
}

create_managed_identity() {
    log_info "Creating User-Assigned Managed Identity: $IDENTITY_NAME..."
    
    # Get location from first region
    local location="${REGIONS[0]}"
    
    # Check if identity already exists
    if az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" &>/dev/null; then
        log_warn "Managed Identity $IDENTITY_NAME already exists"
    else
        az identity create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$IDENTITY_NAME" \
            --location "$location" \
            --output none
        log_info "Managed Identity created: $IDENTITY_NAME"
    fi
    
    # Get identity details
    IDENTITY_CLIENT_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" \
        --query "clientId" -o tsv)
    
    IDENTITY_PRINCIPAL_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" \
        --query "principalId" -o tsv)
    
    log_info "Identity Client ID: $IDENTITY_CLIENT_ID"
}

grant_dns_permissions() {
    log_info "Granting Private DNS Zone Contributor role to identity..."
    
    # Get DNS Zone resource ID
    local dns_zone_id=$(az network private-dns zone show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DNS_ZONE_NAME" \
        --query "id" -o tsv)
    
    if [ -z "$dns_zone_id" ]; then
        log_error "DNS Zone $DNS_ZONE_NAME not found in $RESOURCE_GROUP"
        exit 1
    fi
    
    log_info "DNS Zone ID: $dns_zone_id"
    
    # Check if role assignment already exists
    local existing_assignment=$(az role assignment list \
        --assignee "$IDENTITY_PRINCIPAL_ID" \
        --scope "$dns_zone_id" \
        --role "Private DNS Zone Contributor" \
        --query "[0].id" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$existing_assignment" ]; then
        log_warn "Role assignment already exists"
    else
        az role assignment create \
            --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
            --assignee-principal-type ServicePrincipal \
            --role "Private DNS Zone Contributor" \
            --scope "$dns_zone_id" \
            --output none
        log_info "Role assignment created"
    fi
}

create_federated_credentials() {
    log_info "Creating Federated Identity Credentials for each AKS cluster..."
    
    for region in "${REGIONS[@]}"; do
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local credential_name="neo4j-dns-${region}"
        
        log_info "Processing cluster: $cluster_name"
        
        # Get OIDC issuer URL
        local oidc_issuer=$(az aks show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --query "oidcIssuerProfile.issuerUrl" -o tsv)
        
        if [ -z "$oidc_issuer" ]; then
            log_error "Could not get OIDC issuer for $cluster_name"
            continue
        fi
        
        log_info "OIDC Issuer: $oidc_issuer"
        
        # Check if federated credential already exists
        if az identity federated-credential show \
            --identity-name "$IDENTITY_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$credential_name" &>/dev/null; then
            log_warn "Federated credential $credential_name already exists"
        else
            # Create federated credential
            az identity federated-credential create \
                --identity-name "$IDENTITY_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --name "$credential_name" \
                --issuer "$oidc_issuer" \
                --subject "system:serviceaccount:${NEO4J_NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
                --audiences "api://AzureADTokenExchange" \
                --output none
            
            log_info "Federated credential created: $credential_name"
        fi
    done
}

create_kubernetes_service_accounts() {
    log_info "Creating Kubernetes Service Accounts in each cluster..."
    
    for region in "${REGIONS[@]}"; do
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        
        log_info "Setting up service account in $cluster_name..."
        
        # Get credentials
        az aks get-credentials \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --overwrite-existing \
            --context "$cluster_name"
        
        kubectl config use-context "$cluster_name"
        
        # Ensure namespace exists
        kubectl create namespace "$NEO4J_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
        
        # Create service account with workload identity annotation
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NEO4J_NAMESPACE}
  annotations:
    azure.workload.identity/client-id: "${IDENTITY_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
EOF
        
        log_info "Service account created in $cluster_name"
    done
}

setup_workload_identity() {
    log_info "=========================================="
    log_info "Setting up Workload Identity for DNS"
    log_info "=========================================="
    
    enable_workload_identity_on_clusters
    sleep 10
    
    create_managed_identity
    sleep 5
    
    grant_dns_permissions
    sleep 5
    
    create_federated_credentials
    sleep 5
    
    create_kubernetes_service_accounts
    
    log_info "Workload Identity setup complete"
}

################################################################################
# LoadBalancer Service Functions
################################################################################

create_internal_loadbalancer_services() {
    log_info "Pre-creating internal LoadBalancer services (auto-assigned private IPs)..."
    
    mkdir -p ./yaml
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local helm_release="${HELM_RELEASE_PREFIX}-${region}"
        local lb_service_name="${helm_release}-internal-lb"
        local yaml_file="./yaml/lb-internal-${region}.yaml"
        
        kubectl config use-context "$context"
        
        # Check if service already exists
        if kubectl get svc "$lb_service_name" -n "$NEO4J_NAMESPACE" &>/dev/null; then
            log_warn "Internal LoadBalancer service $lb_service_name already exists, skipping"
            continue
        fi
        
        log_info "Creating internal LoadBalancer service for $lb_service_name (auto-assigned IP)"
        
        cat > "$yaml_file" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${lb_service_name}
  namespace: ${NEO4J_NAMESPACE}
  labels:
    app: neo4j
    app.kubernetes.io/name: neo4j
    app.kubernetes.io/instance: ${helm_release}
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "aks-subnet-${region}"
spec:
  type: LoadBalancer
  publishNotReadyAddresses: true
  externalTrafficPolicy: Cluster
  sessionAffinity: ClientIP
  selector:
    helm.neo4j.com/instance: ${helm_release}
  ports:
    - name: discovery
      port: 6000
      targetPort: 6000
      protocol: TCP
    - name: ssr
      port: 7688
      targetPort: 7688
      protocol: TCP
    - name: backup
      port: 6362
      targetPort: 6362
      protocol: TCP
EOF
        
        log_info "LoadBalancer service file created: $yaml_file"
        kubectl apply -f $yaml_file 
        log_info "Internal LoadBalancer service created for $lb_service_name"
        sleep 5
    done
    
    log_info "Waiting for internal LoadBalancers to be provisioned with private IPs..."
    sleep 30
    
    log_info "Internal LoadBalancer services ready"
}

create_public_loadbalancer_services() {
    log_info "Pre-creating public LoadBalancer services with static IPs..."
    
    mkdir -p ./yaml
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local helm_release="${HELM_RELEASE_PREFIX}-${region}"
        local lb_service_name="${helm_release}-public-lb"
        local static_ip="${STATIC_PUBLIC_IPS[$region]}"
        local yaml_file="./yaml/lb-public-${region}.yaml"
        
        kubectl config use-context "$context"
        
        # Check if service already exists
        if kubectl get svc "$lb_service_name" -n "$NEO4J_NAMESPACE" &>/dev/null; then
            log_warn "Public LoadBalancer service $lb_service_name already exists, skipping"
            continue
        fi
        
        log_info "Creating public LoadBalancer service for $lb_service_name with IP: $static_ip"
        
        cat > "$yaml_file" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${lb_service_name}
  namespace: ${NEO4J_NAMESPACE}
  labels:
    app: neo4j
    app.kubernetes.io/name: neo4j
    app.kubernetes.io/instance: ${helm_release}
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-ipv4: "${static_ip}"
spec:
  type: LoadBalancer
  loadBalancerIP: ${static_ip}
  publishNotReadyAddresses: true
  externalTrafficPolicy: Cluster
  selector:
    helm.neo4j.com/instance: ${helm_release}
  ports:
    - name: http
      port: 7474
      targetPort: 7474
      protocol: TCP
    - name: bolt
      port: 7687
      targetPort: 7687
      protocol: TCP
EOF
        
        log_info "Public LoadBalancer service file created: $yaml_file"
        kubectl apply -f $yaml_file 
        log_info "Public LoadBalancer service created for $lb_service_name"
        sleep 5
    done
    
    log_info "Public LoadBalancer services ready"
}

################################################################################
# Neo4j Deployment Function (with Dynamic DNS for RAFT)
################################################################################

deploy_neo4j_cluster() {
    log_info "Deploying Neo4j cluster members using Helm..."
    log_info "Using init containers for dynamic RAFT DNS registration"
    
    mkdir -p ./yaml
    
    # Build discovery endpoints using DNS names
    local discovery_endpoints=""
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        local lb_internal_dns_name="${release_name}-internal-lb.${DNS_ZONE_NAME}"
        if [ $i -gt 0 ]; then
            discovery_endpoints="${discovery_endpoints},"
        fi
        discovery_endpoints="${discovery_endpoints}${lb_internal_dns_name}:6000"
    done
    
    log_info "Discovery endpoints (DNS): $discovery_endpoints"
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local server_id=$((i + 1))
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        local values_file="./yaml/values-${region}.yaml"
        local lb_internal_dns_name="${release_name}-internal-lb.${DNS_ZONE_NAME}"
        local lb_public_dns_name="${release_name}-public-lb.${DNS_ZONE_NAME}"
        # RAFT DNS name: neo4j-eastus-0-raft.neo4j.internal (pod name + -raft suffix)
        local raft_dns_name="${release_name}-0-raft.${DNS_ZONE_NAME}"
        
        log_info "Deploying Neo4j via Helm: ${GREEN}${release_name} in $region${NC}"
        log_info "RAFT DNS will be: $raft_dns_name"
        kubectl config use-context "$context"
        
        cat > "$values_file" <<EOF
# Neo4j Helm Chart Values for ${region}
# Using Standard Azure CNI - Pod IPs routable across VNet peering
# Init container registers pod IP in Azure Private DNS for direct RAFT communication

image:
  imagePullPolicy: IfNotPresent

nodeSelector:
  workload: neo4j

podSpec:
  tolerations:
    - key: workload
      operator: Equal
      value: neo4j
      effect: NoSchedule
  
  # Service account with Azure DNS permissions (Workload Identity)
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  
  # Required label for AKS Workload Identity to inject env vars
  # NOTE: This label doesn't get applied to pod template by Helm chart
  # The script patches the StatefulSet after deployment to add this label
  labels:
    azure.workload.identity/use: "true"

  initContainers:
    - name: register-dns
      image: mcr.microsoft.com/azure-cli:latest
      env:
        - name: AZURE_CONFIG_DIR
          value: "/tmp/.azure"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: RESOURCE_GROUP
          value: "${RESOURCE_GROUP}"
        - name: DNS_ZONE
          value: "${DNS_ZONE_NAME}"
        - name: REGION
          value: "${region}"
      command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "Registering DNS for pod: \$POD_NAME with IP: \$POD_IP"
          
          # DNS record name: neo4j-eastus-0-raft -> neo4j-eastus-0-raft.neo4j.internal
          RECORD_NAME="\${POD_NAME}-raft"
          
          # Debug: show workload identity env vars
          echo "=== Workload Identity Environment Variables ==="
          echo "AZURE_CLIENT_ID: \$AZURE_CLIENT_ID"
          echo "AZURE_TENANT_ID: \$AZURE_TENANT_ID"
          echo "AZURE_FEDERATED_TOKEN_FILE: \$AZURE_FEDERATED_TOKEN_FILE"
          echo "AZURE_AUTHORITY_HOST: \$AZURE_AUTHORITY_HOST"
          
          if [ -z "\$AZURE_CLIENT_ID" ] || [ -z "\$AZURE_TENANT_ID" ] || [ -z "\$AZURE_FEDERATED_TOKEN_FILE" ]; then
            echo "ERROR: Workload Identity environment variables not injected!"
            echo "Make sure:"
            echo "  1. Pod has label: azure.workload.identity/use=true"
            echo "  2. Service account has annotation: azure.workload.identity/client-id"
            echo "  3. Federated credential is configured correctly"
            exit 1
          fi
          
          if [ ! -f "\$AZURE_FEDERATED_TOKEN_FILE" ]; then
            echo "ERROR: Federated token file does not exist: \$AZURE_FEDERATED_TOKEN_FILE"
            exit 1
          fi
          
          # Login using workload identity (federated token)
          echo "Logging in with federated token..."
          az login --federated-token "\$(cat \$AZURE_FEDERATED_TOKEN_FILE)" \\
            --service-principal -u "\$AZURE_CLIENT_ID" -t "\$AZURE_TENANT_ID"
          
          # Check if record exists
          EXISTING=\$(az network private-dns record-set a show \\
            --resource-group "\$RESOURCE_GROUP" \\
            --zone-name "\$DNS_ZONE" \\
            --name "\$RECORD_NAME" \\
            --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null || echo "")
          
          if [ -n "\$EXISTING" ] && [ "\$EXISTING" != "\$POD_IP" ]; then
            echo "Updating existing DNS record from \$EXISTING to \$POD_IP"
            # Remove old record
            az network private-dns record-set a remove-record \\
              --resource-group "\$RESOURCE_GROUP" \\
              --zone-name "\$DNS_ZONE" \\
              --record-set-name "\$RECORD_NAME" \\
              --ipv4-address "\$EXISTING" \\
              --keep-empty-record-set || true
          fi
          
          if [ "\$EXISTING" != "\$POD_IP" ]; then
            echo "Creating DNS record: \$RECORD_NAME.\$DNS_ZONE -> \$POD_IP"
            # Create record-set with TTL if it doesn't exist, then add record
            az network private-dns record-set a create \\
              --resource-group "\$RESOURCE_GROUP" \\
              --zone-name "\$DNS_ZONE" \\
              --name "\$RECORD_NAME" \\
              --ttl 60 2>/dev/null || true
            az network private-dns record-set a add-record \\
              --resource-group "\$RESOURCE_GROUP" \\
              --zone-name "\$DNS_ZONE" \\
              --record-set-name "\$RECORD_NAME" \\
              --ipv4-address "\$POD_IP"
          else
            echo "DNS record already correct: \$RECORD_NAME.\$DNS_ZONE -> \$POD_IP"
          fi
          
          echo "DNS registration complete"

neo4j:
  name: "${release_name}"
  resources:
    requests:
      cpu: "4"
      memory: "16Gi"
    limits:
      cpu: "8"
      memory: "32Gi"
  password: "${NEO4J_PASSWORD}"
  offlineMaintenanceModeEnabled: false
  edition: "enterprise"
  acceptLicenseAgreement: "yes"
  minimumClusterSize: "3"

  labels:
    app: "${release_name}"

services:
  neo4j:
    enabled: false
  default:
    enabled: true

env:
  NEO4J_PLUGINS: '["apoc", "bloom"]'

config:
  initial.server.mode_constraint: "PRIMARY"
  server.backup.enabled: "true"
  
  dbms.security.procedures.unrestricted: "apoc.*,bloom.*"
  server.unmanaged_extension_classes: "com.neo4j.bloom.server=/bloom"
  dbms.security.http_auth_allowlist: "/,/browser.*,/bloom.*"

  server.directories.plugins: "/var/lib/neo4j/plugins"

  # Discovery using LoadBalancer DNS (works through NAT)
  dbms.cluster.discovery.resolver_type: "LIST"
  dbms.cluster.discovery.version: "V2_ONLY"
  dbms.cluster.discovery.v2.endpoints: "${discovery_endpoints}"

  # Transaction Service - LoadBalancer
  server.cluster.listen_address: "0.0.0.0:6000"
  server.cluster.advertised_address: "${lb_internal_dns_name}:6000"

  # RAFT protocol - Direct pod-to-pod using dynamic DNS registration
  # Init container registers: ${raft_dns_name} -> pod IP
  server.cluster.raft.listen_address: "0.0.0.0:7000"
  server.cluster.raft.advertised_address: "${raft_dns_name}:7000"

  # Client connections
  server.http.enabled: "true"
  server.http.listen_address: "0.0.0.0:7474"
  server.http.advertised_address: "${lb_public_dns_name}:7474"

  server.bolt.listen_address: "0.0.0.0:7687"
  server.bolt.advertised_address: "${lb_public_dns_name}:7687"

  # Cluster routing
  dbms.routing.enabled: "true"
  server.routing.listen_address: "0.0.0.0:7688"
  server.routing.advertised_address: "${lb_internal_dns_name}:7688"
  
  # Memory settings for Standard_E16as_v5 (64GB RAM)
  server.memory.heap.initial_size: "8g"
  server.memory.heap.max_size: "8g"
  server.memory.pagecache.size: "16g"

volumes:
  data:
    mode: defaultStorageClass
    defaultStorageClass:
      requests:
        storage: 100Gi

startupProbe:
  failureThreshold: 60
  periodSeconds: 10

readinessProbe:
  failureThreshold: 10
  initialDelaySeconds: 120
  periodSeconds: 10

livenessProbe:
  enabled: false
EOF
        
        log_info "Helm values file created: $values_file"
        
        log_info "Installing Helm chart for $release_name..."
        helm upgrade --install "$release_name" neo4j/neo4j \
            --namespace "$NEO4J_NAMESPACE" \
            --version "$HELM_CHART_VERSION" \
            --values "$values_file"
        
        log_info "Neo4j Helm release ${release_name} deployed in $region"
        
        # Patch StatefulSet to add workload identity label to pod template
        # This is required because podSpec.labels in Helm values doesn't apply to pod template
        log_info "Patching StatefulSet to add workload identity label..."
        kubectl patch statefulset "$release_name" -n "$NEO4J_NAMESPACE" --type='json' -p='[
          {"op": "add", "path": "/spec/template/metadata/labels/azure.workload.identity~1use", "value": "true"}
        ]'
        log_info "StatefulSet patched with workload identity label"
        
        sleep 10
    done
    
    log_info "All Neo4j pods deployed"
    log_info "Helm values files saved in: ./yaml/"
}

verify_deployments() {
    log_info "Verifying Neo4j cluster deployment..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        
        log_info "Checking Helm release ${release_name} in $region..."

        kubectl config use-context "$context"
        
        helm status "$release_name" -n "$NEO4J_NAMESPACE"
        
        kubectl wait --for=condition=ready pod \
            -l "app.kubernetes.io/instance=${release_name}" \
            -n "$NEO4J_NAMESPACE" \
            --timeout=600s || true
        
        kubectl get pods -n "$NEO4J_NAMESPACE" -l "app.kubernetes.io/instance=${release_name}"
        
        # Get pod IP to verify Standard CNI
        local pod_name=$(kubectl get pods -n "$NEO4J_NAMESPACE" \
            -l "app.kubernetes.io/instance=${release_name}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [ -n "$pod_name" ]; then
            local pod_ip=$(kubectl get pod "$pod_name" -n "$NEO4J_NAMESPACE" \
                -o jsonpath='{.status.podIP}' 2>/dev/null)
            log_info "Pod $pod_name IP: $pod_ip (from pod subnet ${POD_SUBNET_CIDRS[$i]})"
            
            # Verify DNS record was created
            local raft_dns="${pod_name}-raft"
            log_info "Verifying RAFT DNS record: ${raft_dns}.${DNS_ZONE_NAME}"
            local dns_ip=$(az network private-dns record-set a show \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --name "$raft_dns" \
                --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null || echo "not found")
            log_info "  DNS record: ${raft_dns}.${DNS_ZONE_NAME} -> $dns_ip"
        fi
        
        sleep 5
    done
    
    log_info "Deployment verification complete"
}

print_connection_info() {
    log_info "=================================================="
    log_info "  Neo4j Multi-Region Cluster Deployment Complete! "
    log_info "=================================================="
    echo ""
    log_info "Cluster Configuration:"
    log_info "  - Pattern: Geo-distributed 3DC (3 data centers)"
    log_info "  - Regions: ${REGIONS[*]}"
    log_info "  - Each region has 1 primary member"
    log_info "  - Deployed via Helm charts"
    log_info "  - RAFT Protocol: Direct pod-to-pod via Dynamic DNS"
    log_info "  - Discovery/Cluster: LoadBalancer DNS (Port 6000)"
    log_info "  - Cross-region connectivity via VNet peering"
    echo ""
    
    log_info "=========================================="
    log_info "            REGIONAL ENDPOINTS            "
    log_info "=========================================="
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        local int_lb_name="${release_name}-internal-lb"
        local pub_lb_name="${release_name}-public-lb"
        
        kubectl config use-context "$context"
        
        local internal_ip=$(kubectl get svc "$int_lb_name" -n "$NEO4J_NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        local public_ip=$(kubectl get svc "$pub_lb_name" -n "$NEO4J_NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        
        local int_dns_name="${int_lb_name}.${DNS_ZONE_NAME}"
        local pub_dns_name="${pub_lb_name}.${DNS_ZONE_NAME}"
        
        local pod_name=$(kubectl get pods -n "$NEO4J_NAMESPACE" \
            -l "app.kubernetes.io/instance=${release_name}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        local pod_ip=$(kubectl get pod "$pod_name" -n "$NEO4J_NAMESPACE" \
            -o jsonpath='{.status.podIP}' 2>/dev/null || echo "pending")
        
        local raft_dns_name="${pod_name}-raft.${DNS_ZONE_NAME}"
        
        log_info "Region: $region (${release_name})"
        log_info "  Context: $context"
        log_info "  Helm Release: $release_name"
        log_info "  Values File: ./yaml/values-${region}.yaml"
        log_info "  Internal LoadBalancer IP: $internal_ip (private)"
        log_info "  Public LoadBalancer IP: $public_ip"
        log_info "  Pod IP: $pod_ip (from pod subnet ${POD_SUBNET_CIDRS[$i]})"
        log_info "  RAFT DNS: $raft_dns_name -> $pod_ip"
        log_info "  Internal DNS: $int_dns_name"
        log_info "  Public DNS: $pub_dns_name"
        log_info "  Neo4j Browser: http://${pub_dns_name}:7474 (or http://${public_ip}:7474)"
        log_info "  Bolt: bolt://${pub_dns_name}:7687 (or ${public_ip}:7687)"
        log_info "  Username: neo4j"
        log_info "  Password: $NEO4J_PASSWORD"
        echo ""
    done
    
    log_info "=========================================="
    log_info "       CROSS-REGION CONNECTIVITY          "
    log_info "=========================================="
    log_info "Communication Architecture (Dynamic DNS for RAFT):"
    log_info "  * Port 6000 (Discovery/Cluster): Via LoadBalancer DNS"
    log_info "  * Port 7000 (RAFT): Direct pod-to-pod via Dynamic DNS"
    log_info "  * Init container registers pod IP in Azure Private DNS"
    log_info "  * VNet peering: Full mesh across all regions"
    log_info "  * Pod IPs routable across peered VNets (Standard CNI)"
    log_info "  * DNS resolution: Azure Private DNS (${DNS_ZONE_NAME})"
    echo ""
    log_info "RAFT DNS Records (dynamically registered by init container):"
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        local raft_dns="${release_name}-0-raft"
        
        local dns_ip=$(az network private-dns record-set a show \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$raft_dns" \
            --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null || echo "pending")
        
        log_info "  * ${raft_dns}.${DNS_ZONE_NAME} -> ${dns_ip}"
    done
    echo ""
    log_info "Pod Subnet Configuration:"
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        log_info "  * ${region}: ${POD_SUBNET_CIDRS[$i]}"
    done
    echo ""
    log_info "LoadBalancer DNS Records (for Discovery/Client):"
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        local int_lb_name="${release_name}-internal-lb"
        
        kubectl config use-context "$context"
        local internal_ip=$(kubectl get svc "$int_lb_name" -n "$NEO4J_NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        
        log_info "  * ${int_lb_name}.${DNS_ZONE_NAME} ==> ${internal_ip} (private)"
    done
    echo ""
    
    log_warn "IMPORTANT: Change the default password immediately!"
    log_info "To verify cluster formation:"
    log_info "  Connect to Neo4j Browser and run: SHOW SERVERS;"
    echo ""
    log_info "To verify RAFT DNS resolution:"
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local release_name="${HELM_RELEASE_PREFIX}-${region}"
        log_info "  nslookup ${release_name}-0-raft.${DNS_ZONE_NAME}"
    done
    echo ""
    log_info "To verify pod-to-pod RAFT connectivity:"
    log_info "  kubectl exec -n $NEO4J_NAMESPACE <pod-name> -- nc -zv <remote-pod-ip> 7000"
    echo ""
    log_info "To check RAFT connections in logs:"
    log_info "  kubectl logs -n $NEO4J_NAMESPACE <pod-name> | grep 'RAFT\\|7000\\|Initializing server channel'"
    echo ""
}

main() {
    log_info "Starting Multi-Region Neo4j Cluster Deployment on AKS"
    log_info "Using Dynamic DNS Registration for direct pod-to-pod RAFT"
    echo ""
    
    check_prerequisites
    sleep 2
    
    add_helm_repo
    sleep 2
    
    get_latest_k8s_version
    sleep 2
    
    create_resource_group
    sleep 5
    
    create_vnets
    sleep 10
    
    create_vnet_peering
    sleep 15
    
    create_aks_clusters
    sleep 20
    
    log_info "=========================================="
    log_info "RAFT Communication Strategy (Dynamic DNS)"
    log_info "=========================================="
    log_info "Port 6000 (Discovery): LoadBalancer DNS"
    log_info "Port 7000 (RAFT): Direct pod-to-pod via Dynamic DNS"
    log_info "  - Init container registers pod IP in Azure Private DNS"
    log_info "  - RAFT address: neo4j-<region>-0-raft.neo4j.internal"
    log_info ""
    verify_nsg_rules
    
    log_info "=========================================="
    log_info "Network Pre-Allocation Phase"
    log_info "=========================================="
    
    allocate_static_ips
    sleep 10
    
    create_private_dns_zone
    sleep 10
    
    create_internal_loadbalancer_services
    create_public_loadbalancer_services
    sleep 30
    
    create_dns_records
    sleep 10
    
    log_info "=========================================="
    log_info "Workload Identity Setup Phase"
    log_info "=========================================="
    
    setup_workload_identity
    sleep 10
    
    log_info "=========================================="
    log_info "Neo4j Deployment Phase"
    log_info "=========================================="
    
    deploy_neo4j_cluster
    sleep 30
    
    verify_deployments
    sleep 5
    
    print_connection_info
    
    log_info "Deployment complete!"
}

main