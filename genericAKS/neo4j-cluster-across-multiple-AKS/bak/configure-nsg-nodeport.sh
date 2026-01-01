#!/bin/bash

################################################################################
# Configure NSG Rules for Neo4j Cross-Region NodePort Communication
# This script adds required firewall rules to allow NodePort 30700 between node subnets
################################################################################

set -e

RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")

# Node/AKS subnet CIDRs (where nodes run, and NodePort traffic flows)
NODE_CIDRS=("10.1.0.0/20" "10.2.0.0/20" "10.3.0.0/20")

# NodePort for RAFT
RAFT_NODEPORT=30700

echo "=========================================="
echo "Neo4j NSG Configuration (NodePort Strategy)"
echo "=========================================="
echo ""
echo "This script will configure Network Security Groups to allow"
echo "TCP port ${RAFT_NODEPORT} (RAFT NodePort) between node subnets across all regions."
echo ""
echo "Node Subnets (AKS subnets):"
for i in "${!REGIONS[@]}"; do
  echo "  ${REGIONS[$i]}: ${NODE_CIDRS[$i]}"
done
echo ""
echo "Required Ports:"
echo "  - ${RAFT_NODEPORT}: RAFT NodePort (critical for cluster formation)"
echo "  - 6000: Discovery (via LoadBalancer, but allowing direct)"
echo "  - 7688: Server-side routing (via LoadBalancer, but allowing direct)"
echo ""

for region in "${REGIONS[@]}"; do
  echo ""
  echo "=== Processing region: $region ==="
  
  # Get node resource group
  echo "Getting node resource group..."
  NODE_RG=$(az aks show \
    --resource-group $RESOURCE_GROUP \
    --name neo4j-aks-$region \
    --query nodeResourceGroup -o tsv)
  
  if [ -z "$NODE_RG" ]; then
    echo "ERROR: Could not find node resource group for neo4j-aks-$region"
    echo "Make sure AKS cluster exists"
    continue
  fi
  
  echo "Node resource group: $NODE_RG"
  
  # Get NSG name
  echo "Getting NSG name..."
  NSG_NAME=$(az network nsg list \
    --resource-group $NODE_RG \
    --query "[?contains(name, 'aks-agentpool')].name" -o tsv | head -1)
  
  if [ -z "$NSG_NAME" ]; then
    echo "ERROR: Could not find NSG in $NODE_RG"
    continue
  fi
  
  echo "NSG name: $NSG_NAME"
  
  # Check if inbound rule exists
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Inbound &>/dev/null; then
    echo "Inbound rule already exists, updating..."
    az network nsg rule update \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-RAFT-Inbound \
      --priority 100 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "${NODE_CIDRS[@]}" \
      --source-port-ranges '*' \
      --destination-address-prefixes "${NODE_CIDRS[@]}" \
      --destination-port-ranges $RAFT_NODEPORT 6000 7688 \
      --description "Allow Neo4j cross-region RAFT (NodePort ${RAFT_NODEPORT}) and cluster communication"
    echo "✓ Inbound rule updated"
  else
    echo "Creating inbound rule..."
    az network nsg rule create \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-RAFT-Inbound \
      --priority 100 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "${NODE_CIDRS[@]}" \
      --source-port-ranges '*' \
      --destination-address-prefixes "${NODE_CIDRS[@]}" \
      --destination-port-ranges $RAFT_NODEPORT 6000 7688 \
      --description "Allow Neo4j cross-region RAFT (NodePort ${RAFT_NODEPORT}) and cluster communication"
    echo "✓ Inbound rule created"
  fi
  
  # Check if outbound rule exists
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Outbound &>/dev/null; then
    echo "Outbound rule already exists, updating..."
    az network nsg rule update \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-RAFT-Outbound \
      --priority 100 \
      --direction Outbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "${NODE_CIDRS[@]}" \
      --source-port-ranges '*' \
      --destination-address-prefixes "${NODE_CIDRS[@]}" \
      --destination-port-ranges $RAFT_NODEPORT 6000 7688 \
      --description "Allow Neo4j cross-region RAFT (NodePort ${RAFT_NODEPORT}) and cluster communication"
    echo "✓ Outbound rule updated"
  else
    echo "Creating outbound rule..."
    az network nsg rule create \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-RAFT-Outbound \
      --priority 100 \
      --direction Outbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "${NODE_CIDRS[@]}" \
      --source-port-ranges '*' \
      --destination-address-prefixes "${NODE_CIDRS[@]}" \
      --destination-port-ranges $RAFT_NODEPORT 6000 7688 \
      --description "Allow Neo4j cross-region RAFT (NodePort ${RAFT_NODEPORT}) and cluster communication"
    echo "✓ Outbound rule created"
  fi
done

echo ""
echo "=========================================="
echo "NSG configuration complete!"
echo "=========================================="
echo ""
echo "Verifying rules..."
echo ""

for region in "${REGIONS[@]}"; do
  echo "=== Rules for $region ==="
  NODE_RG=$(az aks show \
    --resource-group $RESOURCE_GROUP \
    --name neo4j-aks-$region \
    --query nodeResourceGroup -o tsv 2>/dev/null)
  
  if [ -z "$NODE_RG" ]; then
    echo "  Cluster not found, skipping"
    echo ""
    continue
  fi
  
  NSG_NAME=$(az network nsg list \
    --resource-group $NODE_RG \
    --query "[?contains(name, 'aks-agentpool')].name" -o tsv 2>/dev/null | head -1)
  
  if [ -z "$NSG_NAME" ]; then
    echo "  NSG not found, skipping"
    echo ""
    continue
  fi
  
  echo "Inbound rule:"
  az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Inbound \
    --query "{Name:name, Priority:priority, Direction:direction, Access:access, Protocol:protocol, SourcePrefixes:sourceAddressPrefixes, DestPrefixes:destinationAddressPrefixes, DestPorts:destinationPortRanges}" \
    -o table 2>/dev/null || echo "  Not found"
  
  echo ""
  echo "Outbound rule:"
  az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Outbound \
    --query "{Name:name, Priority:priority, Direction:direction, Access:access, Protocol:protocol, SourcePrefixes:sourceAddressPrefixes, DestPrefixes:destinationAddressPrefixes, DestPorts:destinationPortRanges}" \
    -o table 2>/dev/null || echo "  Not found"
  
  echo ""
done

echo "=========================================="
echo "Rule Summary"
echo "=========================================="
echo "Allowed Traffic Flow:"
echo "  From: 10.1.0.0/20, 10.2.0.0/20, 10.3.0.0/20"
echo "  To:   10.1.0.0/20, 10.2.0.0/20, 10.3.0.0/20"
echo "  Ports: ${RAFT_NODEPORT}, 6000, 7688"
echo ""
echo "This allows:"
echo "  - RAFT traffic via NodePort ${RAFT_NODEPORT} on node IPs"
echo "  - Discovery traffic on port 6000"
echo "  - Server-side routing on port 7688"
echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo "1. Verify rules were created successfully above"
echo "2. Run: bash deployNeo4jMultiRegionNodePort.sh"
echo "3. After deployment, test connectivity:"
echo "   # Get node IP from each region"
echo "   kubectl get nodes -o wide"
echo ""
echo "   # Test RAFT NodePort from any pod"
echo "   kubectl exec -n neo4j <pod-name> -- nc -zv <remote-node-ip> ${RAFT_NODEPORT}"
echo ""
echo "   # Example:"
echo "   kubectl exec -n neo4j neo4j-eastus-0 -- nc -zv 10.2.0.50 ${RAFT_NODEPORT}"
echo ""
