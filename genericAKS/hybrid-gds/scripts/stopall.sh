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

# Azure CLI to stop nodepool
echo "Deleting nodepool..."
az aks nodepool delete --cluster-name neo4j-aks-hybrid-cluster  --nodepool-name neo4j --no-wait

#echo "Deleting AKS cluster (not waiting)..."
#az aks delete --name neo4j-aks-hybrid-cluster --no-wait --yes
echo "Deleting AKS cluster..."
az aks delete --name neo4j-aks-hybrid-cluster --yes

#echo "The AKS cluster will be deleted in several minutes"

# Remove backup cron job
#helm uninstall jhair-backup