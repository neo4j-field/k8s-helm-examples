AKS_RESOURCE_GROUP=jhair-helm
AKS_REGION=eastus

AKS_CLUSTER_NAME=neo4j-aks-hybrid-cluster
AKS_NAMESPACE=neo4j-hybrid
AKS_NODEPOOL_NAME=neo4j

# List the defaults
echo "Azure default settings"
az configure -l

echo "Uninstalling pods..."
helm uninstall playsmall-1 playsmall-2 playsmall-3
helm uninstall playsmall-gds-1
#echo Sleeping 30 seconds
#sleep 30

# Delete load balancer
echo "Deleting load balancers..."
kubectl delete -f playsmall-lb.yaml --wait=false
kubectl delete -f playsmall-gds1-lb.yaml --wait=false

#echo Delete/cleanup pods for core members
#kubectl get pods -o=name | awk '/playsmall[0-9]-cleanup/{print $1}'| xargs kubectl delete -n efs 
#shouldn't be any gds cleanup

#echo Delete/cleanup pods for gds members
#kubectl get pods -o=name | awk '/playsmall-gds[0-9]-cleanup/{print $1}'| xargs kubectl delete -n efs 
#sleep 30

# Azure CLI to delete the nodepool
echo "Deleting nodepool (${AKS_NODEPOOL_NAME}) from the cluster (${AKS_CLUSTER_NAME})..."
az aks nodepool delete --cluster-name ${AKS_CLUSTER_NAME}  --nodepool-name ${AKS_NODEPOOL_NAME} --no-wait

#echo "Deleting AKS cluster (not waiting)..."
#az aks delete --name neo4j-aks-hybrid-cluster --no-wait --yes
echo "Deleting AKS cluster (${AKS_CLUSTER_NAME})..."
az aks delete --name ${AKS_CLUSTER_NAME} --yes

#echo "The AKS cluster will be deleted in several minutes"

# Remove backup cron job
#helm uninstall jhair-backup