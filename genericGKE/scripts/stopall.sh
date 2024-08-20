echo "Deleting the LB..."
kubectl delete -f standalone-lb.yaml

echo "Uninstalling Neo4j from the GKE cluster..."
helm uninstall standalone