AKS_RESOURCE_GROUP=jhair-helm-rg
AKS_REGION=eastus

AKS_CLUSTER_NAME=neo4j-aks-hybrid-cluster
AKS_NAMESPACE=neo4j-hybrid
AKS_NODEPOOL_NAME=neo4j

# List the defaults
echo "Azure default settings"
az configure -l

echo "Uninstalling pods..."
helm uninstall neo4j-core-1 neo4j-core-2 neo4j-core-3
helm uninstall neo4j-gds-1
#echo Sleeping 30 seconds
#sleep 30

# Delete load balancer
echo "Deleting load balancers..."
kubectl delete -f neo4j-core-lb.yaml --wait=false
kubectl delete -f neo4j-gds-lb.yaml --wait=false

#echo Delete/cleanup pods for core members
#kubectl get pods -o=name | awk '/playsmall[0-9]-cleanup/{print $1}'| xargs kubectl delete -n efs 
#shouldn't be any gds cleanup

#echo Delete/cleanup pods for gds members
#kubectl get pods -o=name | awk '/playsmall-gds[0-9]-cleanup/{print $1}'| xargs kubectl delete -n efs 
#sleep 30

# Azure CLI to delete the nodepool
echo "Deleting nodepool (${AKS_NODEPOOL_NAME}) from the cluster (${AKS_CLUSTER_NAME})..."
az aks nodepool delete --cluster-name ${AKS_CLUSTER_NAME}  --nodepool-name ${AKS_NODEPOOL_NAME} --no-wait

echo "Deleting AKS cluster ${AKS_CLUSTER_NAME} (not waiting)..."
az aks delete --name ${AKS_CLUSTER_NAME} --no-wait --yes

#echo "The AKS cluster will be deleted in several minutes"

# Remove backup cron job
#helm uninstall jhair-backup