GKE_CLUSTER_NAME=jhair-gke-cluster

echo "Uninstalling Neo4j Reverse Proxy from the GKE cluster..."
helm uninstall rp

echo "Removing Nginx Ingress Controller..."
helm uninstall ingress-nginx -n ingress-nginx