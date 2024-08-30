GKE_CLUSTER_NAME=jhair-gke-cluster

echo "Deleting the LB..."
kubectl delete -f standalone-lb.yaml

echo "Uninstalling Neo4j from the GKE cluster..."
helm uninstall standalone

echo "Deleting the GKE cluster..."
gcloud container clusters delete --async $GKE_CLUSTER_NAME 