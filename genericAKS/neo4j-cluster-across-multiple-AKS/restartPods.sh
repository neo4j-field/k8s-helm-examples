echo "Restarting pods to establish fresh RAFT connections..."

for region in eastus westus2 centralus; do
  echo "Restarting pod in $region..."
  kubectl config use-context neo4j-aks-${region}
  kubectl delete pods -n neo4j -l helm.neo4j.com/instance=neo4j-${region} --grace-period=30
  sleep 15
done

echo "Waiting for pods to stabilize (60 seconds)..."
sleep 60

echo "Checking pod status..."
for region in eastus westus2 centralus; do
  kubectl config use-context neo4j-aks-${region}
  echo "=== $region ==="
  kubectl get pods -n neo4j
done