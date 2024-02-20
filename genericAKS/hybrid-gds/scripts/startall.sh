# Firstly, create a resource group
# az group create --name jhair-helm

# Set the resource group in the defaults
#az configure --defaults group=jhair-helm

# List the defaults
echo "Azure default settings"
az configure -l


# Node count creates a 'system node pool'
echo "Creating AKS cluster..."
az aks create --name neo4j-aks-hybrid-cluster
az aks get-credentials --overwrite-existing --name neo4j-aks-hybrid-cluster --admin

echo "Creating namespace..."
kubectl create namespace neo4j-hybrid
kubectl config set-context --current --namespace=neo4j-hybrid

kubectl create configmap license-config --from-file=../licenses/

# Azure CLI to start nodepool
#az aks nodepool start --resource-group myResourceGroup --cluster-name neo4j-aks-hybrid-cluster --nodepool-name neo4j_np
echo "Creating nodepool..."
az aks nodepool add --cluster-name neo4j-aks-hybrid-cluster \
  --nodepool-name neo4j --node-count 4 \
  --enable-cluster-autoscaler --min-count 1 --max-count 6 \
  --labels "nodegroup=playsmall" \
  --node-vm-size Standard_E16as_v5

echo "Sleeping 30 seconds to allow nodepool to start..."
sleep 30

echo "Creating Neo4j pods..."
helm upgrade -i playsmall-1  neo4j/neo4j --namespace neo4j-hybrid -f hybrid-core-small.yaml 
sleep 5
helm upgrade -i playsmall-2  neo4j/neo4j --namespace neo4j-hybrid -f hybrid-core-small.yaml
sleep 5
helm upgrade -i playsmall-3  neo4j/neo4j --namespace neo4j-hybrid -f hybrid-core-small.yaml
sleep 5
helm upgrade -i playsmall-gds-1  neo4j/neo4j --namespace neo4j-hybrid -f hybrid-gds-small.yaml 

# Create load balancers
echo "Creating load balancers..."
kubectl apply -f playsmall-lb.yaml
kubectl apply -f playsmall-gds1-lb.yaml