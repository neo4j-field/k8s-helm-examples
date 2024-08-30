GKE_CLUSTER_NAME=jhair-gke-cluster

#
# List the defaults
#
echo "GKE default settings"
gcloud config list

echo "Configuring kubectl to use the cluster..."
gcloud container clusters get-credentials $GKE_CLUSTER_NAME

echo "Creating Nginx Ingress Controller within $GKE_CLUSTER_NAME..."
helm upgrade --install ingress-nginx ingress-nginx \
      --repo https://kubernetes.github.io/ingress-nginx \
      --namespace ingress-nginx --create-namespace

echo "Install the Reverse proxy Helm chart within the GKE cluster..."
helm install rp neo4j/neo4j-reverse-proxy -f ingress-values.yaml -n neo4j