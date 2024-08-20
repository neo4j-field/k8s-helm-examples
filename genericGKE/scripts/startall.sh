GKE_CLUSTER_NAME=jhair-gke-cluster
GKE_CLUSTER_NODE_COUNT=1
GKE_INSTANCE_TYPE=e2-standard-2

# Configure via environment variables or set defaults in gcloud config (below)
#export CLOUDSDK_CORE_PROJECT="my-neo4j-project"
#export CLOUDSDK_COMPUTE_ZONE="europe-west2-a"
#export CLOUDSDK_COMPUTE_REGION="europe-west2"

#
# List the defaults
#
echo "GKE default settings"
gcloud config list

#
# Creating K8s namespace
#
echo "Creating GKE cluster - $GKE_CLUSTER_NAME..."
# The number of nodes to be created in each of the cluster’s zones. You can set
# this to 1 to create a single node cluster, but it needs at least 3 nodes to
# build a Kubernetes cluster.
gcloud container clusters create $GKE_CLUSTER_NAME --num-nodes=$GKE_CLUSTER_NODE_COUNT --machine-type "$GKE_INSTANCE_TYPE"

echo "Configuring kubectl to use the cluster..."
gcloud container clusters get-credentials $GKE_CLUSTER_NAME

#
# Creating K8s namespace
#
echo "Create a neo4j namespace and configure it to be used in the current context"
kubectl create namespace neo4j
kubectl config set-context --current --namespace=neo4j

#
# Create secret for Neo4j's password - only needs created once
#
./createPasswordSecret.sh

#
# Create config map for license files
#
./create-licenses-configmap.sh

#
# Create storage classes
#
./createStorageClass.sh

echo "Deploying Neo4j to the GKE cluster..."
#helm install standalone  neo4j/neo4j --namespace neo4j -f standalone.yaml 
helm upgrade -i standalone  neo4j/neo4j -f standalone.yaml 

echo "Deploying LB..."
kubectl apply -f standalone-lb.yaml

echo "Run the kubectl rollout command provided in the output of helm install to watch the Neo4j’s rollout until it is complete."
echo "kubectl --namespace "neo4j" rollout status --watch --timeout=600s statefulset/standalone"