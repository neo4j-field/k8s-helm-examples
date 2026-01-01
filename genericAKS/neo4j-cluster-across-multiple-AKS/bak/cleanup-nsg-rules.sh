#!/bin/bash

################################################################################
# Remove Old NSG Rules for Neo4j
# This script removes previous NSG rules before applying NodePort configuration
################################################################################

set -e

RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")

echo "=========================================="
echo "Removing Old Neo4j NSG Rules"
echo "=========================================="
echo ""
echo "This script will remove old NSG rules configured for pod IPs."
echo "These rules will be removed:"
echo "  - Allow-Neo4j-Inbound"
echo "  - Allow-Neo4j-Outbound"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."
echo ""

for region in "${REGIONS[@]}"; do
  echo ""
  echo "=== Processing region: $region ==="
  
  # Get node resource group
  echo "Getting node resource group..."
  NODE_RG=$(az aks show \
    --resource-group $RESOURCE_GROUP \
    --name neo4j-aks-$region \
    --query nodeResourceGroup -o tsv 2>/dev/null)
  
  if [ -z "$NODE_RG" ]; then
    echo "WARNING: Could not find node resource group for neo4j-aks-$region"
    echo "AKS cluster may not exist. Skipping..."
    continue
  fi
  
  echo "Node resource group: $NODE_RG"
  
  # Get NSG name
  echo "Getting NSG name..."
  NSG_NAME=$(az network nsg list \
    --resource-group $NODE_RG \
    --query "[?contains(name, 'aks-agentpool')].name" -o tsv 2>/dev/null | head -1)
  
  if [ -z "$NSG_NAME" ]; then
    echo "WARNING: Could not find NSG in $NODE_RG"
    echo "Skipping..."
    continue
  fi
  
  echo "NSG name: $NSG_NAME"
  
  # Remove old inbound rule
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Inbound &>/dev/null; then
    echo "Removing old inbound rule: Allow-Neo4j-Inbound"
    az network nsg rule delete \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-Inbound
    echo "✓ Old inbound rule removed"
  else
    echo "Old inbound rule not found (may have been removed already)"
  fi
  
  # Remove old outbound rule
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Outbound &>/dev/null; then
    echo "Removing old outbound rule: Allow-Neo4j-Outbound"
    az network nsg rule delete \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-Outbound
    echo "✓ Old outbound rule removed"
  else
    echo "Old outbound rule not found (may have been removed already)"
  fi
  
  # Also check for and remove any RAFT rules if they exist (in case of re-run)
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Inbound &>/dev/null; then
    echo "Found existing RAFT inbound rule, removing..."
    az network nsg rule delete \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-RAFT-Inbound
    echo "✓ Existing RAFT inbound rule removed"
  fi
  
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Outbound &>/dev/null; then
    echo "Found existing RAFT outbound rule, removing..."
    az network nsg rule delete \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name Allow-Neo4j-RAFT-Outbound
    echo "✓ Existing RAFT outbound rule removed"
  fi
done

echo ""
echo "=========================================="
echo "Cleanup complete!"
echo "=========================================="
echo ""
echo "Verifying rules are removed..."
echo ""

for region in "${REGIONS[@]}"; do
  echo "=== Checking $region ==="
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
  
  # Check for old rules
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Inbound &>/dev/null; then
    echo "  ⚠️  WARNING: Allow-Neo4j-Inbound still exists!"
  else
    echo "  ✓ Allow-Neo4j-Inbound removed"
  fi
  
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-Outbound &>/dev/null; then
    echo "  ⚠️  WARNING: Allow-Neo4j-Outbound still exists!"
  else
    echo "  ✓ Allow-Neo4j-Outbound removed"
  fi
  
  # Check for RAFT rules
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Inbound &>/dev/null; then
    echo "  ⚠️  WARNING: Allow-Neo4j-RAFT-Inbound still exists!"
  else
    echo "  ✓ Allow-Neo4j-RAFT-Inbound removed (or never existed)"
  fi
  
  if az network nsg rule show \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --name Allow-Neo4j-RAFT-Outbound &>/dev/null; then
    echo "  ⚠️  WARNING: Allow-Neo4j-RAFT-Outbound still exists!"
  else
    echo "  ✓ Allow-Neo4j-RAFT-Outbound removed (or never existed)"
  fi
  
  echo ""
done

echo "=========================================="
echo "All Neo4j NSG Rules Removed"
echo "=========================================="
echo ""
echo "Remaining NSG rules for reference:"
echo ""

for region in "${REGIONS[@]}"; do
  NODE_RG=$(az aks show \
    --resource-group $RESOURCE_GROUP \
    --name neo4j-aks-$region \
    --query nodeResourceGroup -o tsv 2>/dev/null)
  
  if [ -z "$NODE_RG" ]; then
    continue
  fi
  
  NSG_NAME=$(az network nsg list \
    --resource-group $NODE_RG \
    --query "[?contains(name, 'aks-agentpool')].name" -o tsv 2>/dev/null | head -1)
  
  if [ -z "$NSG_NAME" ]; then
    continue
  fi
  
  echo "=== $region ($NSG_NAME) ==="
  az network nsg rule list \
    --resource-group $NODE_RG \
    --nsg-name $NSG_NAME \
    --query "[].{Name:name, Priority:priority, Direction:direction, Access:access, Protocol:protocol, DestPorts:destinationPortRanges}" \
    --output table
  echo ""
done

echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo "1. Old NSG rules have been removed"
echo "2. Run: bash configure-nsg-nodeport.sh"
echo "   (This will create new NodePort rules)"
echo ""
