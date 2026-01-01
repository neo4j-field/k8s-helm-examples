#!/bin/bash

################################################################################
# Quick NSG Verification Script
# Checks if port 30700 is allowed in NSG rules
################################################################################

set -e

RESOURCE_GROUP="jhair_mrc_rg"
REGIONS=("eastus" "westus2" "centralus")

echo "=========================================="
echo "Checking NSG Rules for NodePort 30700"
echo "=========================================="
echo ""

# Step 1: List all NSGs
echo "Step 1: Finding Network Security Groups..."
echo ""

NSG_LIST=$(az network nsg list -g $RESOURCE_GROUP --query "[].name" -o tsv)

if [ -z "$NSG_LIST" ]; then
  echo "❌ ERROR: No NSGs found in resource group $RESOURCE_GROUP"
  echo ""
  echo "This is unexpected. NSGs should be automatically created with AKS."
  echo "Check if the resource group name is correct."
  exit 1
fi

echo "Found NSGs:"
echo "$NSG_LIST"
echo ""

# Step 2: Check for port 30700 rules in each NSG
echo "=========================================="
echo "Step 2: Checking for Port 30700 Rules"
echo "=========================================="
echo ""

PORT_30700_RULES_FOUND=0

for nsg in $NSG_LIST; do
  echo "=== NSG: $nsg ==="
  
  # Check for port 30700 inbound rules
  INBOUND_RULES=$(az network nsg rule list -g $RESOURCE_GROUP --nsg-name $nsg \
    --query "[?destinationPortRange=='30700' || destinationPortRanges[?contains(@, '30700')]].{Name:name,Priority:priority,Direction:direction,Source:sourceAddressPrefix,Dest:destinationAddressPrefix,Port:destinationPortRange}" \
    -o table 2>/dev/null)
  
  if [ -n "$INBOUND_RULES" ] && [ "$INBOUND_RULES" != "[]" ]; then
    echo "  ✅ Found port 30700 rules:"
    echo "$INBOUND_RULES"
    PORT_30700_RULES_FOUND=$((PORT_30700_RULES_FOUND + 1))
  else
    echo "  ❌ No port 30700 rules found"
  fi
  
  echo ""
done

echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""

if [ $PORT_30700_RULES_FOUND -eq 0 ]; then
  echo "❌ CRITICAL: No NSG rules found for port 30700!"
  echo ""
  echo "This explains why RAFT connections are failing with 'Connection refused'."
  echo ""
  echo "REQUIRED ACTION:"
  echo "  Run the configure-nsg-nodeport.sh script to add the required rules:"
  echo ""
  echo "  cd /mnt/user-data/outputs"
  echo "  bash configure-nsg-nodeport.sh"
  echo ""
  echo "After running the script:"
  echo "  1. Wait 30 seconds for rules to propagate"
  echo "  2. Re-run this verification script"
  echo "  3. Test connectivity with: bash diagnose-raft-connectivity.sh"
  echo "  4. Restart Neo4j pods"
  echo ""
else
  echo "✅ Found port 30700 rules in $PORT_30700_RULES_FOUND NSG(s)"
  echo ""
  echo "NSG rules appear to be configured. If cluster still not forming:"
  echo ""
  echo "1. Check if rules cover all node subnets:"
  echo "   - 10.1.0.0/20 (eastus)"
  echo "   - 10.2.0.0/20 (westus2)"
  echo "   - 10.3.0.0/20 (centralus)"
  echo ""
  echo "2. Test actual connectivity:"
  echo "   bash diagnose-raft-connectivity.sh"
  echo ""
  echo "3. Check for Azure Firewall or other policies blocking traffic"
  echo ""
  echo "4. Restart pods to establish fresh connections:"
  echo "   for region in eastus westus2 centralus; do"
  echo "     kubectl config use-context neo4j-aks-\${region}"
  echo "     kubectl delete pods -n neo4j -l helm.neo4j.com/instance=neo4j-\${region}"
  echo "   done"
  echo ""
fi

# Step 3: Show current AKS node subnets for reference
echo "=========================================="
echo "Reference: AKS Node Subnets"
echo "=========================================="
echo ""

for region in "${REGIONS[@]}"; do
  echo "=== $region ==="
  
  VNET_NAME="neo4j-vnet-${region}"
  SUBNET_NAME="aks-subnet-${region}"
  
  SUBNET_INFO=$(az network vnet subnet show \
    -g $RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --name $SUBNET_NAME \
    --query "{Prefix:addressPrefix,NSG:networkSecurityGroup.id}" \
    -o json 2>/dev/null)
  
  if [ -n "$SUBNET_INFO" ] && [ "$SUBNET_INFO" != "null" ]; then
    echo "$SUBNET_INFO" | jq -r '"  Subnet: \(.Prefix)\n  NSG: \(.NSG // "None")"'
  else
    echo "  Could not retrieve subnet info"
  fi
  
  echo ""
done

echo "Port 30700 rules MUST allow traffic between all these subnets."
echo ""
