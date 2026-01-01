#!/bin/bash

# Fix LoadBalancer selectors and test connectivity

echo "=========================================="
echo "Step 1: Check Current Endpoints"
echo "=========================================="
for region in eastus westus2 centralus; do
  kubectl config use-context neo4j-aks-${region}
  echo "=== $region ==="
  echo "Current selector:"
  kubectl get svc neo4j-${region}-lb -n neo4j -o jsonpath='{.spec.selector}' | jq '.'
  echo "Current endpoints:"
  kubectl get endpoints neo4j-${region}-lb -n neo4j -o jsonpath='{.subsets[*].addresses[*].ip}'
  echo ""
  echo ""
done

echo "=========================================="
echo "Step 2: Fix Selectors to Match Pod Labels"
echo "=========================================="
for region in eastus westus2 centralus; do
  kubectl config use-context neo4j-aks-${region}
  
  # Check actual pod labels
  echo "=== $region - Pod Labels ==="
  kubectl get pod neo4j-${region}-0 -n neo4j --show-labels 2>/dev/null | grep -o "app=[^,]*"
  
  echo "Patching selector to: app=neo4j-${region}"
  kubectl patch svc neo4j-${region}-lb -n neo4j --type merge -p "{
    \"spec\": {
      \"selector\": {
        \"app\": \"neo4j-${region}\"
      }
    }
  }"
  
  echo "Waiting for endpoints to populate..."
  sleep 5
  
  ENDPOINTS=$(kubectl get endpoints neo4j-${region}-lb -n neo4j -o jsonpath='{.subsets[*].addresses[*].ip}')
  if [ -z "$ENDPOINTS" ]; then
    echo "❌ FAILED: No endpoints for neo4j-${region}-lb"
    echo "   Checking if pod is ready..."
    kubectl get pod neo4j-${region}-0 -n neo4j -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    echo ""
  else
    echo "✅ SUCCESS: Endpoints: $ENDPOINTS"
  fi
  echo ""
done

echo "=========================================="
echo "Step 3: Test Cross-Region Connectivity"
echo "=========================================="

kubectl config use-context neo4j-aks-eastus

# Create debug pod if not exists
if ! kubectl get pod netdebug -n neo4j &>/dev/null; then
  echo "Creating debug pod..."
  kubectl run netdebug --image=nicolaka/netshoot --restart=Never -n neo4j -- sleep 3600
  kubectl wait --for=condition=ready pod/netdebug -n neo4j --timeout=60s
fi

echo "Testing from eastus to other regions..."
echo ""

for target_region in westus2 centralus; do
  TARGET_DNS="neo4j-${target_region}-lb.neo4j.internal"
  
  echo "=== Testing eastus -> $target_region ==="
  
  # Test DNS
  echo "DNS lookup:"
  kubectl exec netdebug -n neo4j -- nslookup $TARGET_DNS | grep "Address:"
  
  # Test port 6000 (discovery)
  echo -n "Port 6000 (discovery): "
  if timeout 5 kubectl exec netdebug -n neo4j -- nc -zv -w 3 $TARGET_DNS 6000 2>&1 | grep -q "succeeded\|open"; then
    echo "✅ Connected"
  else
    echo "❌ Failed (timeout)"
  fi
  
  # Test port 7000 (raft)
  echo -n "Port 7000 (raft): "
  if timeout 5 kubectl exec netdebug -n neo4j -- nc -zv -w 3 $TARGET_DNS 7000 2>&1 | grep -q "succeeded\|open"; then
    echo "✅ Connected"
  else
    echo "❌ Failed (timeout)"
  fi
  
  # Test port 7687 (bolt)
  echo -n "Port 7687 (bolt): "
  if timeout 5 kubectl exec netdebug -n neo4j -- nc -zv -w 3 $TARGET_DNS 7687 2>&1 | grep -q "succeeded\|open"; then
    echo "✅ Connected"
  else
    echo "❌ Failed (timeout)"
  fi
  
  echo ""
done

echo "=========================================="
echo "Step 4: Summary"
echo "=========================================="

ALL_GOOD=true

for region in eastus westus2 centralus; do
  kubectl config use-context neo4j-aks-${region}
  ENDPOINTS=$(kubectl get endpoints neo4j-${region}-lb -n neo4j -o jsonpath='{.subsets[*].addresses[*].ip}')
  
  if [ -z "$ENDPOINTS" ]; then
    echo "❌ neo4j-${region}-lb: NO ENDPOINTS"
    ALL_GOOD=false
  else
    echo "✅ neo4j-${region}-lb: $ENDPOINTS"
  fi
done

echo ""
if [ "$ALL_GOOD" = true ]; then
  echo "✅ All LoadBalancers have endpoints"
  echo ""
  echo "Next steps:"
  echo "1. Check Neo4j logs: kubectl logs neo4j-eastus-0 -n neo4j --tail=100"
  echo "2. Wait for cluster to form (may take 2-3 minutes)"
  echo "3. Verify: kubectl exec neo4j-eastus-0 -n neo4j -- cypher-shell -u neo4j -p 'ChangeThisPassword123!' 'SHOW SERVERS;'"
else
  echo "❌ Some LoadBalancers missing endpoints"
  echo ""
  echo "Troubleshooting:"
  echo "1. Check pod readiness: kubectl get pods -n neo4j"
  echo "2. Check pod labels: kubectl get pods -n neo4j --show-labels"
  echo "3. Check service selector: kubectl get svc neo4j-eastus-lb -n neo4j -o yaml | grep -A 3 selector"
fi

# Cleanup debug pod
echo ""
echo "Cleanup: kubectl delete pod netdebug -n neo4j"
