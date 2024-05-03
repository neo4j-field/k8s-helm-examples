AKS_RESOURCE_GROUP=jhair-helm
AKS_REGION=eastus

# Set the resource group in the defaults
az configure --defaults location=${AKS_REGION}
az configure --defaults group=${AKS_RESOURCE_GROUP}

# List the defaults
echo "Azure default settings"
az configure -l

# Create a resource group if it doesn't exist
if ! `az group exists --name ${AKS_RESOURCE_GROUP}`; then
   az group create --location ${AKS_REGION}--name ${AKS_RESOURCE_GROUP}
else
   echo "Resource Group, ${AKS_RESOURCE_GROUP}, exists"
fi

# Node count creates a 'system node pool'
echo "Creating AKS cluster..."
az aks create --name neo4j-aks-hybrid-cluster --resource-group ${AKS_RESOURCE_GROUP}
# --enable-oidc-issuer

# Get the cluster node resource group
MC_RG_NAME="$(az aks show --name cs-americas-aks-cluster --query nodeResourceGroup --output tsv)"

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

# TODO Alter topology for neo4j DB to 3 PRIMARY 1 SECONDARY
#ALTER DATABASE neo4j SET TOPOLOGY 3 PRIMARY 1 SECONDARY

# Create backup schedule
#helm install my-neo4j-backup . \
    # --set neo4jaddr=neo4j-aks-hybrid-cluster.default.svc.cluster.local:6362 \
    # --set bucket=jhairstorage \
    # --set database="neo4j\,system" \
    # --set cloudProvider=azure \
    # --set secretName=neo4j-azure-credentials \
    # --set jobSchedule="30 * * * *"
#helm install jhair-backup neo4j/neo4j-admin -f backup-values.yaml

kubectl get pods
kubectl get services
# kubectl run --rm -it --image "neo4j:5.16.0-enterprise" cypher-shell -- cypher-shell -a "neo4j://playsmall-3.default.svc.cluster.local:7687" -u neo4j -p "my-password"