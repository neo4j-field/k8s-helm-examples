#!/bin/bash

################################################################################
# Configure NSG Rules for Neo4j Cross-Region Communication
# This script adds required firewall rules to allow ports 6000, 7000, 7688 between pod subnets
################################################################################

set -e

RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")

# Pod CIDRs as array for proper Azure CLI handling
POD_CIDRS=("10.1.0.0/20" "10.2.0.0/20" "10.3.0.0/20")
# Node Subnet CIDRs
NODE_CIDRS=("10.1.0.0/20" "10.2.0.0/20" "10.3.0.0/20")

echo "=========================================="
echo "Neo4j NSG Configuration"
echo "=========================================="
echo ""
echo "This script will configure Network Security Groups to allow"
echo "TCP ports 6000, 7000, 7688 between pod subnets across all regions."
echo ""
echo "Pod Subnets:"
for i in "${!REGIONS[@]}"; do
  echo "  ${REGIONS[$i]}: ${NODE_CIDRS[$i]}"
done
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
  
  echo "Node resource group: $NODE_RG"
  
  # Get NSG name
  echo "Getting NSG name..."
  NSG_NAME=$(az network nsg list \
    --resource-group $NODE_RG \
    --query "[?contains(name, 'aks-agentpool')].name" -o tsv | head -1)
  
  echo "NSG name: $NSG_NAME"
  
  # Check if inbound rule exists
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Inbound &>/dev/null; then
    echo "Inbound rule already exists, skipping"
  else
    echo "Creating inbound rule..."
    # Use array expansion to pass multiple CIDRs properly
    az network nsg rule create \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-Inbound \
      --priority 100 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "${NODE_CIDRS[@]}" \
      --source-port-ranges '*' \
      --destination-address-prefixes "${NODE_CIDRS[@]}" \
      --destination-port-ranges 6000 7000 7688 30700 \
      --description "Allow Neo4j cross-region communication (ports 6000, 7000, 7688)"
    echo "✓ Inbound rule created"
  fi
  
  # Check if outbound rule exists
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Outbound &>/dev/null; then
    echo "Outbound rule already exists, skipping"
  else
    echo "Creating outbound rule..."
    # Use array expansion to pass multiple CIDRs properly
    az network nsg rule create \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-Outbound \
      --priority 100 \
      --direction Outbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "${NODE_CIDRS[@]}" \
      --source-port-ranges '*' \
      --destination-address-prefixes "${NODE_CIDRS[@]}" \
      --destination-port-ranges 6000 7000 7688 30700 \
      --description "Allow Neo4j cross-region communication (ports 6000, 7000, 7688)"
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
    --query nodeResourceGroup -o tsv)
  NSG_NAME=$(az network nsg list \
    --resource-group $NODE_RG \
    --query "[?contains(name, 'aks-agentpool')].name" -o tsv | head -1)
  
  echo "Inbound rule:"
  az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Inbound \
    --query "{Name:name, Priority:priority, Direction:direction, Access:access, Protocol:protocol, SourcePrefixes:sourceAddressPrefixes, DestPrefixes:destinationAddressPrefixes, DestPorts:destinationPortRanges}" \
    -o table 2>/dev/null || echo "  Not found"
  
  echo ""
  echo "Outbound rule:"
  az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Outbound \
    --query "{Name:name, Priority:priority, Direction:direction, Access:access, Protocol:protocol, SourcePrefixes:sourceAddressPrefixes, DestPrefixes:destinationAddressPrefixes, DestPorts:destinationPortRanges}" \
    -o table 2>/dev/null || echo "  Not found"
  
  echo ""
done

echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo "1. Verify rules were created successfully above"
echo "2. Run: bash deployNeo4jMultiRegion-PodIP.sh"
echo "3. After deployment, test connectivity:"
echo "   kubectl exec -n neo4j <pod-name> -- nc -zv <remote-pod-ip> 6000"
echo "   kubectl exec -n neo4j <pod-name> -- nc -zv <remote-pod-ip> 7000"
echo "   kubectl exec -n neo4j <pod-name> -- nc -zv <remote-pod-ip> 7688"
echo ""