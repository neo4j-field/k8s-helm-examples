#!/usr/bin/env bash

################################################################################
# Multi-Region Neo4j Cluster Deployment on AKS using Helm
# This script deploys a 3-region Neo4j cluster using official Helm charts:
# - 3 Azure regions for geo-distribution
# - Hub-spoke network topology per region
# - VNet peering for cross-region communication
# - Neo4j Enterprise in cluster mode via Helm
################################################################################

set -e  # Exit on error
# set -x

# Configuration
RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")
CLUSTER_NAME_PREFIX="neo4j-aks"
VNET_PREFIX="neo4j-vnet"
NEO4J_VERSION="5.26.0"  # Neo4j Enterprise version
NEO4J_NAMESPACE="neo4j"
NEO4J_PASSWORD="ChangeThisPassword123!"  # Change in production
HELM_RELEASE_PREFIX="neo4j"
HELM_CHART_VERSION="5.26.16"  # Neo4j Helm chart version
DNS_ZONE_NAME="neo4j.internal"  # Private DNS zone name

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
POD_CIDRS=("10.1.16.0/20" "10.2.16.0/20" "10.3.16.0/20")

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
    
    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI not found. Please install it."
        exit 1
    fi
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install it."
        exit 1
    fi
    
    # Check Helm
    if ! command -v helm &> /dev/null; then
        log_error "Helm not found. Please install it: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    # Check Azure login
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Run 'az login'"
        exit 1
    fi
    
    log_info "All prerequisites met"
}

get_latest_k8s_version() {
    log_info "Detecting latest supported non-LTS Kubernetes version in ${REGIONS[0]}..."
    
    # Get all available non-preview versions
    local versions=$(az aks get-versions \
        --location "${REGIONS[0]}" \
        --query "values[?isPreview==null].version" \
        --output tsv 2>/dev/null)
    
    # Filter out LTS versions (1.28.x and 1.30.x are LTS) and pick the latest
    # Looking for 1.29.x or 1.31.x versions
    local available_version=""
    for version in $versions; do
        # Skip LTS versions (currently 1.28.x and 1.30.x)
        if [[ ! "$version" =~ ^1\.28\. ]] && [[ ! "$version" =~ ^1\.30\. ]]; then
            available_version="$version"
            break
        fi
    done
    
    if [ -n "$available_version" ]; then
        K8S_VERSION="$available_version"
        log_info "Using Kubernetes version: $K8S_VERSION (non-LTS)"
    else
        # Fallback: explicitly try 1.29
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
        
        log_info "Creating VNet: $vnet_name in $region"
        
        # Create VNet
        az network vnet create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$vnet_name" \
            --location "$region" \
            --address-prefix "${REGION_CIDRS[$i]}" \
            --output none
        
        # Create AKS subnet
        az network vnet subnet create \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$vnet_name" \
            --name "$aks_subnet" \
            --address-prefixes "${AKS_SUBNET_CIDRS[$i]}" \
            --output none
        
        log_info "VNet $vnet_name created"
        sleep 5
    done
}

create_vnet_peering() {
    log_info "Creating VNet peering for cross-region communication (full mesh)..."
    
    # Create full mesh peering: connect all regions to each other
    for i in "${!REGIONS[@]}"; do
        for j in "${!REGIONS[@]}"; do
            # Skip self-peering
            if [ "$i" -eq "$j" ]; then
                continue
            fi
            
            local source_region="${REGIONS[$i]}"
            local target_region="${REGIONS[$j]}"
            local peering_name="peer-${source_region}-to-${target_region}"
            local source_vnet="${VNET_PREFIX}-${source_region}"
            local target_vnet="${VNET_PREFIX}-${target_region}"
            
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
    
    # Array to store allocated public IPs
    declare -g -A STATIC_PUBLIC_IPS
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local public_ip_name="neo4j-public-lb-ip-${region}"
        
        # Get the AKS node resource group (MC_* resource group)
        local node_rg=$(az aks show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --query nodeResourceGroup -o tsv)

        log_info "Allocating static public IP in $region: $public_ip_name"
        
        # Create static public IP
        az network public-ip create \
            --resource-group "$node_rg" \
            --name "$public_ip_name" \
            --sku Standard \
            --allocation-method Static \
            --location "$region" \
            --output none
        
        # Get the allocated IP address
        local ip_address=$(az network public-ip show \
            --resource-group "$node_rg" \
            --name "$public_ip_name" \
            --query ipAddress -o tsv)
        
        STATIC_PUBLIC_IPS[$region]="$ip_address"
        log_info "Public static IP allocated for $region: $ip_address"
        sleep 3
    done
    
    log_info "All static public IPs allocated"
    
    # Debug: Show all allocated IPs
    log_info "Allocated public IP addresses:"
    for region in "${REGIONS[@]}"; do
        log_info "  ${region} public: ${STATIC_PUBLIC_IPS[$region]}"
    done
}

create_private_dns_zone() {
    log_info "Creating Azure Private DNS Zone for LoadBalancer DNS..."
    
    # Check if DNS zone already exists
    if az network private-dns zone show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DNS_ZONE_NAME" &>/dev/null; then
        log_warn "Private DNS Zone $DNS_ZONE_NAME already exists, skipping creation"
    else
        # Create Private DNS Zone
        az network private-dns zone create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$DNS_ZONE_NAME" \
            --output none
        
        log_info "Private DNS Zone created: $DNS_ZONE_NAME"
    fi
    
    # Link DNS zone to all VNets
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local vnet_name="${VNET_PREFIX}-${region}"
        local link_name="dns-link-${region}"
        
        log_info "Linking DNS zone to VNet: $vnet_name"
        
        # Check if link already exists
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
    
    # Note: Internal IPs will be retrieved from actual LoadBalancer services
    # Public IPs come from pre-allocated static IPs
    
    # Create individual DNS records for each region
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local int_release_name="${HELM_RELEASE_PREFIX}-${region}-internal-lb"
        local pub_release_name="${HELM_RELEASE_PREFIX}-${region}-public-lb"
        
        kubectl config use-context "$context"
        
        # Get internal LoadBalancer IP (auto-assigned by Azure)
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
        
        log_info "Creating DNS record: ${int_release_name}.${DNS_ZONE_NAME} -> $internal_ip_address"
        
        # Check if record already exists
        if az network private-dns record-set a show \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$int_release_name" &>/dev/null; then
            
            log_warn "DNS record ${int_release_name}.${DNS_ZONE_NAME} already exists"
            
            # Get existing IP
            local existing_ip=$(az network private-dns record-set a show \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --name "$int_release_name" \
                --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null)
            
            if [ "$existing_ip" != "$internal_ip_address" ]; then
                log_warn "Existing IP ($existing_ip) differs from current IP ($internal_ip_address), updating..."
                
                # Remove old record
                az network private-dns record-set a remove-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$int_release_name" \
                    --ipv4-address "$existing_ip" \
                    --output none 2>/dev/null || true
                
                # Add new record
                az network private-dns record-set a add-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$int_release_name" \
                    --ipv4-address "$internal_ip_address" \
                    --output none
                
                log_info "DNS A record updated for $int_release_name"
            else
                log_info "DNS record already points to correct IP, skipping"
            fi
        else
            # Create new record
            az network private-dns record-set a add-record \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --record-set-name "$int_release_name" \
                --ipv4-address "$internal_ip_address" \
                --output none
            
            log_info "DNS A record created for $int_release_name"
        fi
        
        ######### Public IP (from pre-allocated static IPs)
        local pub_ip_address="${STATIC_PUBLIC_IPS[$region]}"
        
        # Validate IP address exists
        if [ -z "$pub_ip_address" ]; then
            log_error "No public IP address found for region: $region"
            return 1
        fi
        
        log_info "Creating DNS record: ${pub_release_name}.${DNS_ZONE_NAME} -> $pub_ip_address"
        
        # Check if record already exists
        if az network private-dns record-set a show \
            --resource-group "$RESOURCE_GROUP" \
            --zone-name "$DNS_ZONE_NAME" \
            --name "$pub_release_name" &>/dev/null; then
            
            log_warn "DNS record ${pub_release_name}.${DNS_ZONE_NAME} already exists"
            
            # Get existing IP
            local existing_ip=$(az network private-dns record-set a show \
                --resource-group "$RESOURCE_GROUP" \
                --zone-name "$DNS_ZONE_NAME" \
                --name "$pub_release_name" \
                --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null)
            
            if [ "$existing_ip" != "$pub_ip_address" ]; then
                log_warn "Existing IP ($existing_ip) differs from current IP ($pub_ip_address), updating..."
                
                # Remove old record
                az network private-dns record-set a remove-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$pub_release_name" \
                    --ipv4-address "$existing_ip" \
                    --output none 2>/dev/null || true
                
                # Add new record
                az network private-dns record-set a add-record \
                    --resource-group "$RESOURCE_GROUP" \
                    --zone-name "$DNS_ZONE_NAME" \
                    --record-set-name "$pub_release_name" \
                    --ipv4-address "$pub_ip_address" \
                    --output none
                
                log_info "DNS A record updated for $pub_release_name"
            else
                log_info "DNS record already points to correct IP, skipping"
            fi
        else
            # Create new record
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
    log_info "\nCreating AKS clusters in each region..."
    
    # Define zones per region (some regions don't support zones)
    declare -A REGION_ZONES
    REGION_ZONES["eastus"]="1 2 3"
    REGION_ZONES["westus2"]="2"
    REGION_ZONES["centralus"]="1 2 3"
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local vnet_name="${VNET_PREFIX}-${region}"
        local subnet_name="aks-subnet-${region}"
        local zones="${REGION_ZONES[$region]}"
        
        log_info "Creating AKS cluster: ${GREEN}$cluster_name in $region${NC}"
        
        # Get subnet ID
        local subnet_id=$(az network vnet subnet show \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$vnet_name" \
            --name "$subnet_name" \
            --query id -o tsv)
        
        # Build AKS create command
        local aks_cmd="az aks create \
            --resource-group $RESOURCE_GROUP \
            --name $cluster_name \
            --location $region \
            --kubernetes-version $K8S_VERSION \
            --nodepool-name systempool \
            --node-count $AKS_SYSTEM_NODE_COUNT \
            --node-vm-size $AKS_SYSTEM_NODE_VM_SIZE \
            --network-plugin azure \
            --network-plugin-mode overlay \
            --vnet-subnet-id $subnet_id \
            --pod-cidr ${POD_CIDRS[$i]} \
            --service-cidr 10.$((i+10)).0.0/16 \
            --dns-service-ip 10.$((i+10)).0.10 \
            --enable-managed-identity \
            --node-osdisk-size 128 \
            --output none"
        
        # Add zones if supported
        if [ -n "$zones" ]; then
            aks_cmd="$aks_cmd --zones $zones"
        fi
        
        # Execute with warning suppression
        eval "$aks_cmd" 2>&1 | grep -v "docker_bridge_cidr" || true
        
        log_info "AKS cluster $cluster_name created with system node pool"
        
        # Wait for cluster to be ready
        wait_for_deployment "aks" "$cluster_name" "$RESOURCE_GROUP"
        
        # Build nodepool add command
        local nodepool_cmd="az aks nodepool add \
            --resource-group $RESOURCE_GROUP \
            --cluster-name $cluster_name \
            --name neo4jpool \
            --node-count $AKS_NEO4J_NODE_COUNT \
            --node-vm-size $AKS_NEO4J_NODE_VM_SIZE \
            --labels workload=neo4j \
            --node-taints workload=neo4j:NoSchedule \
            --enable-cluster-autoscaler \
            --min-count 4 \
            --max-count 8 \
            --node-osdisk-size 256 \
            --output none"
        
        # Add zones if supported
        if [ -n "$zones" ]; then
            nodepool_cmd="$nodepool_cmd --zones $zones"
        fi
        
        # Add dedicated Neo4j node pool
        log_info "Adding dedicated Neo4j node pool to $cluster_name"
        eval "$nodepool_cmd" 2>&1 | grep -v "docker_bridge_cidr" || true
        
        log_info "Neo4j node pool added to $cluster_name"

        # Create namespace
        log_info "Create $NEO4J_NAMESPACE namespace"
        kubectl create namespace "$NEO4J_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

        # Get credentials
        az aks get-credentials \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --context "$cluster_name" \
            --overwrite-existing
        
        log_info "Credentials for $cluster_name retrieved"
        sleep 10
    done
}

configure_coredns_azure_forwarding() {
    log_info "Configuring CoreDNS to forward to Azure DNS..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        
        log_info "Configuring CoreDNS in $cluster_name"
        kubectl config use-context "$context"
        
        # Backup existing CoreDNS ConfigMap
        kubectl get configmap coredns -n kube-system -o yaml > "coredns-backup-${region}.yaml" 2>/dev/null || true
        
        # Get current CoreDNS config
        local current_config=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
        
        # Check if forwarding already configured
        if echo "$current_config" | grep -q "${DNS_ZONE_NAME}"; then
            log_warn "CoreDNS already configured for ${DNS_ZONE_NAME} in $cluster_name"
            continue
        fi
        
        # Create new CoreDNS configuration with Azure DNS forwarding
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
    ${DNS_ZONE_NAME}:53 {
        errors
        cache 30
        forward . 168.63.129.16
    }
EOF
        
        log_info "CoreDNS configured to forward ${DNS_ZONE_NAME} to Azure DNS (168.63.129.16)"
        
        # Restart CoreDNS pods to apply changes
        log_info "Restarting CoreDNS pods in $cluster_name..."
        kubectl rollout restart deployment coredns -n kube-system
        kubectl rollout status deployment coredns -n kube-system --timeout=120s
        
        log_info "CoreDNS restarted in $cluster_name"
        sleep 5
    done
    
    log_info "CoreDNS configuration complete across all clusters"
}

configure_dns_service_discovery() {
    log_info "Configuring DNS-based service discovery..."
    
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        
        log_info "Configuring DNS in $cluster_name"
        kubectl config use-context "$context"
        
        # Create namespace
        kubectl create namespace "$NEO4J_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
        
        # Create headless service for cluster-wide DNS discovery
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: neo4j-cluster-dns
  namespace: ${NEO4J_NAMESPACE}
  labels:
    app: neo4j
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - name: discovery
      port: 6000
      targetPort: 6000
    - name: raft
      port: 7000
      targetPort: 7000
  selector:
    app.kubernetes.io/name: neo4j
EOF
        
        log_info "DNS service discovery configured in $cluster_name"
        sleep 5
    done
    
    log_info "DNS configuration complete across all clusters"
}

create_internal_loadbalancer_services() {
    log_info "Pre-creating internal LoadBalancer services (auto-assigned private IPs)..."
    
    mkdir -p ./yaml
    for i in 0 1 2; do
        local region="${REGIONS[$i]}"
        local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
        local context="$cluster_name"
        local helm_release="${HELM_RELEASE_PREFIX}-${region}"
        local lb_service_name="${helm_release}-internal-lb"
        local dns_name="${helm_release}-internal-lb.${DNS_ZONE_NAME}"
        local yaml_file="./yaml/lb-internal-${region}.yaml"
        
        log_info "Creating internal LoadBalancer service for $lb_service_name (auto-assigned IP)"
        kubectl config use-context "$context"
        
        # Create LoadBalancer service WITHOUT static IP - Azure will auto-assign from subnet
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
    service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "30"
spec:
  type: LoadBalancer
  # No loadBalancerIP specified - Azure auto-assigns private IP from VNet subnet
  publishNotReadyAddresses: true
  externalTrafficPolicy: Cluster  # Ensure proper routing
  sessionAffinity: ClientIP       # Maintain connection affinity
  selector:
    helm.neo4j.com/instance: ${helm_release}
  ports:
    - name: discovery
      port: 6000
      targetPort: 6000
      protocol: TCP
    - name: raft
      port: 7000
      targetPort: 7000
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
        local dns_name="${helm_release}-public-lb.${DNS_ZONE_NAME}"
        local yaml_file="./yaml/lb-public-${region}.yaml"
        
        log_info "Creating public LoadBalancer service for $lb_service_name with IP: $static_ip"
        kubectl config use-context "$context"
        
        # Create LoadBalancer service with static IP
        # Selector matches Neo4j Helm chart labels: app.kubernetes.io/instance = release name
        # cat <<EOF | kubectl apply -f -
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
    # service.beta.kubernetes.io/azure-load-balancer-resource-group: "MC_${RESOURCE_GROUP}_${cluster_name}"
    # service.beta.kubernetes.io/azure-pip-name: "neo4j-lb-ip-${region}"
spec:
  type: LoadBalancer
  loadBalancerIP: ${static_ip}
  # Endpoints are created for pods regardless of readiness state
  # Pods are added to DNS records and service endpoints immediately
  publishNotReadyAddresses: true
  externalTrafficPolicy: Cluster
  selector:
    # app: ${helm_release}
    # app.kubernetes.io/name: neo4j
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
    
    log_info "Waiting for LoadBalancers to be provisioned..."
    sleep 30
    
    # Verify LoadBalancers are ready
    # for i in 0 1 2; do
    #     local region="${REGIONS[$i]}"
    #     local cluster_name="${CLUSTER_NAME_PREFIX}-${region}"
    #     local context="$cluster_name"
    #     local lb_service_name="${HELM_RELEASE_PREFIX}-${region}-internal-lb"
        
    #     kubectl config use-context "$context"
        
    #     log_info "Verifying LoadBalancer for $lb_service_name..."
    #     kubectl get svc "${lb_service_name}" -n "$NEO4J_NAMESPACE"
        
    #     # Check if endpoints are populated
    #     local endpoints=$(kubectl get endpoints "${lb_service_name}" -n "$NEO4J_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    #     if [ -z "$endpoints" ]; then
    #         log_warn "No endpoints for $lb_service_name yet (pods may not be running)"
    #     else
    #         log_info "Endpoints found: $endpoints"
    #     fi
    #     sleep 3
    # done
    
    log_info "Public LoadBalancer services ready"
}

deploy_neo4j_cluster() {
    log_info "Deploying Neo4j cluster members using Helm..."
    
    # Create directory for values files
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
        # discovery_endpoints="${discovery_endpoints}${release_name}.${NEO4J_NAMESPACE}.svc.cluster.local:6000
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
        
        log_info "Deploying Neo4j via Helm: ${GREEN}${release_name} in $region${NC}"
        kubectl config use-context "$context"
        
        # Create Helm values file
        cat > "$values_file" <<EOF
# Neo4j Helm Chart Values for ${region}
# Image configuration
image:
  imagePullPolicy: IfNotPresent

# Node selector and tolerations for dedicated node pool
nodeSelector:
  workload: neo4j

podSpec:
  tolerations:
    - key: workload
      operator: Equal
      value: neo4j
      effect: NoSchedule   # Must match the taint's effect

neo4j:
  name: "${release_name}"
  # Resources for Standard_E16as_v5 (64GB RAM)
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
    kubernetes.azure.com/nodepool-type: "primary"

# Service configuration - Disable default service creation (we created it manually)
services:
  neo4j:
    # Do not create the LB
    enabled: false
#  Â   annotations:
#  Â     service.beta.kubernetes.io/azure-load-balancer-internal: "true"
  default:
    enabled: false

env:
  NEO4J_PLUGINS: '["apoc", "bloom"]'

# Clustering configuration
config:
  # Server mode
  initial.server.mode_constraint: "PRIMARY"
#   server.config.strict_validation: "false"
  server.backup.enabled: "true"
  
  dbms.security.procedures.unrestricted: "apoc.*,bloom.*"
  server.unmanaged_extension_classes: "com.neo4j.bloom.server=/bloom"
  dbms.security.http_auth_allowlist: "/,/browser.*,/bloom.*"

  server.directories.plugins: "/var/lib/neo4j/plugins"

  # Multi-cluster discovery using LoadBalancer IPs
  dbms.cluster.discovery.resolver_type: "DNS"
  dbms.cluster.discovery.version: "V2_ONLY"
  dbms.cluster.discovery.v2.endpoints: "${discovery_endpoints}"

  # Discovery service
  server.discovery.listen_address: "0.0.0.0:6000"
  server.discovery.advertised_address: "${lb_internal_dns_name}:6000"
  
  # Transaction Service
  server.cluster.listen_address: "0.0.0.0:6000"
  server.cluster.advertised_address: "${lb_internal_dns_name}:6000"

  # RAFT protocol
  server.cluster.raft.listen_address: "0.0.0.0:7000"
  server.cluster.raft.advertised_address: "${lb_internal_dns_name}:7000"

  server.default_listen_address: "0.0.0.0"
  server.default_advertised_address: "${lb_public_dns_name}"

  # Bolt protocol
  server.bolt.listen_address: "0.0.0.0:7687"
  server.bolt.advertised_address: "${lb_public_dns_name}:7687"

  # Cluster server-side routing
  dbms.routing.enabled: "true"
  server.routing.advertised_address: "${lb_internal_dns_name}:7688"
  server.routing.listen_address: "0.0.0.0:7688"
  
  # Memory settings for Standard_E16as_v5 (64GB RAM)
  server.memory.heap.initial_size: "8g"
  server.memory.heap.max_size: "8g"
  server.memory.pagecache.size: "16g"
  
  # Thread settings
#   server.threads.worker_count: "16"

# Volume configuration
volumes:
  data:
    mode: defaultStorageClass
    defaultStorageClass:
      requests:
        storage: 100Gi
    # mode: dynamic
    # dynamic:
    #   storageClassName: "managed-csi-premium"
    #   requests:
    #     storage: 100Gi

# # Startup and health probes
startupProbe:
#   enabled: false
  failureThreshold: 60
  periodSeconds: 10

# Allow 20 minutes
readinessProbe:
#   enabled: false
  failureThreshold: 10
  initialDelaySeconds: 120
  periodSeconds: 10

livenessProbe:
  enabled: false
#   failureThreshold: 10
#   periodSeconds: 10
EOF
        
        log_info "Helm values file created: $values_file"
        
        # Install Neo4j using Helm
        log_info "Installing Helm chart for $release_name..."
        # set -x
        helm upgrade --install "$release_name" neo4j/neo4j \
            --namespace "$NEO4J_NAMESPACE" \
            --version "$HELM_CHART_VERSION" \
            --values "$values_file"
            # --wait \
            # --timeout 15m
        # set +x
        
        log_info "Neo4j Helm release ${release_name} deployed in $region"
        sleep 10
    done
    
    log_info "All Neo4j pods deployed"
    log_info "Helm values files saved in: ./neo4j-helm-values/"
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
        
        # Check Helm release status
        helm status "$release_name" -n "$NEO4J_NAMESPACE"
        
        # Wait for pods to be ready
        kubectl wait --for=condition=ready pod \
            -l "app.kubernetes.io/instance=${release_name}" \
            -n "$NEO4J_NAMESPACE" \
            --timeout=300s || true
        
        # Get pod status
        kubectl get pods -n "$NEO4J_NAMESPACE" -l "app.kubernetes.io/instance=${release_name}"
        
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
    log_info "  - DNS-based service discovery via Azure Private DNS"
    log_info "  - Cross-region connectivity via VNet peering and DNS"
    log_info "  - High availability and fault tolerance"
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
        
        # Get actual LoadBalancer IPs
        local internal_ip=$(kubectl get svc "$int_lb_name" -n "$NEO4J_NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        local public_ip=$(kubectl get svc "$pub_lb_name" -n "$NEO4J_NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        
        local int_dns_name="${int_lb_name}.${DNS_ZONE_NAME}"
        local pub_dns_name="${pub_lb_name}.${DNS_ZONE_NAME}"
        
        log_info "Region: $region (${release_name})"
        log_info "  Context: $context"
        log_info "  Helm Release: $release_name"
        log_info "  Values File: ./yaml/values-${region}.yaml"
        log_info "  Internal LoadBalancer IP: $internal_ip (private)"
        log_info "  Public LoadBalancer IP: $public_ip"
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
    log_info "Each LoadBalancer can reach Neo4j in all regions:"
    log_info "  * VNet peering: Full mesh across all regions"
    log_info "  * Internal LBs use PRIVATE IPs from VNet subnets"
    log_info "  * DNS resolution: Azure Private DNS (${DNS_ZONE_NAME})"
    log_info "  * Cluster communication: Via internal LB private IPs"
    echo ""
    log_info "Internal DNS Records:"
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
    
    log_info "Client Connection Options:"
    log_info "  1. Direct to region via public IP"
    log_info "  2. Via DNS (public): bolt://<region>-public-lb.${DNS_ZONE_NAME}:7687"
    log_info "  3. Application-level routing (recommended for production)"
    echo ""
    
    log_info "Helm Values Files Location:"
    log_info "  - Directory: ./yaml/"
    log_info "  - One values.yaml per region"
    echo ""
    
    log_warn "IMPORTANT: Change the default password immediately!"
    log_info "To connect to any cluster:"
    log_info "  kubectl config use-context ${CLUSTER_NAME_PREFIX}-<region>"
    log_info "  kubectl get pods -n $NEO4J_NAMESPACE"
    echo ""
    log_info "To verify cluster formation:"
    log_info "  Connect to Neo4j Browser and run: SHOW SERVERS;"
    echo ""
    log_info "To test CoreDNS Azure DNS forwarding:"
    log_info "  kubectl run -it --rm debug --image=busybox --restart=Never -n $NEO4J_NAMESPACE -- nslookup <lb-name>.${DNS_ZONE_NAME}"
    echo ""
    log_info "To verify cross-region connectivity:"
    log_info "  kubectl exec -n neo4j <pod-name> -- nc -zv neo4j-<region>-internal-lb.${DNS_ZONE_NAME} 6000"
    echo ""
    log_info "To manage Helm releases:"
    log_info "  helm list -n $NEO4J_NAMESPACE"
    log_info "  helm upgrade -i ${HELM_RELEASE_PREFIX}-<region> neo4j/neo4j -n $NEO4J_NAMESPACE -f ./yaml/values-<region>.yaml"
    log_info "  helm uninstall ${HELM_RELEASE_PREFIX}-<region> -n $NEO4J_NAMESPACE"
}

main() {
    log_info "Starting Multi-Region Neo4j Cluster Deployment on AKS (using Helm)"
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
    log_info "Network Pre-Allocation Phase"
    log_info "=========================================="
    
    # Only allocate PUBLIC static IPs
    allocate_static_ips
    sleep 10
    
    create_private_dns_zone
    sleep 10
    
    # Create LoadBalancers BEFORE DNS records
    create_internal_loadbalancer_services
    create_public_loadbalancer_services
    sleep 30
    
    # Now create DNS records after LoadBalancers have IPs
    create_dns_records
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

# Run main function
main