# AKS deployment examples

## Windows Pre-requisites
- Get Kubectl
    - ```https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/```
- Get helm
    - ```https://github.com/helm/helm/releases```
- Get Azure CLI
    - ```https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?tabs=azure-cli```

## Mac Pre-requisites
There are multiple ways on Mac, and I have used brew, shell scripts and untar/zip the exe and put on the path.  I have found that brew is just easier to keep up to date.  Helm and kubectl are updated frequently.
- Get Kubectl
    - ```https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/```
- Get helm
    - ```https://helm.sh/docs/intro/install/```
- Get Azure CLI
    - ```https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-macos`

## Azure Pre-requisites
- Login to Azure CLI
    - ```az login```
    - reply back your subscription
- Set default location/region
    - ```az configure --defaults location=eastus```    
- Create/Verify the you have a Resource Group
    - ```az group create --name <resource-group-name>-RG```
- Set default resource group
    - ```az configure --defaults group=<resource-group-name>-RG```

- List defaults
    - ```az configure -l```

## Look at hybrid-gds/scripts/startall.sh for copolete example

## [Neo4j 3 node cluster within 1 AKS cluster](neo4j-core-cluster.yaml)
Neo4j docs - https://neo4j.com/docs/operations-manual/current/kubernetes/quickstart-cluster/

az aks create -g drose-rg --name drose-demo2a --node-count=2   --os-sku Ubuntu \
--load-balancer-sku Standard \
--nodepool-name agentpool1 --node-osdisk-size 128 --node-vm-size Standard_D4ds_v5 \
--enable-addons azure-keyvault-secrets-provider --enable-oidc-issuer \
--enable-workload-identity --generate-ssh-keys

az aks nodepool add --cluster-name drose-demo2a --name neo4jpool1 --resource-group drose-rg --mode User --node-count 3 --node-vm-size Standard_D4as_v5

### Pre-req:
- Azure resource group exists
- AKS cluster exists (e.g. neo4j-aks-cluster)
- Namespace within the AKS cluster exists (e.g neo4j)

### Create Simple Standalone
```
# install the simple standalone chart
helm upgrade -i simplesa  neo4j/neo4j -f  simple_standalone.yaml
#look at the pods
kubectl get po
#describe the pods
kubectl describe po simplesa-0
kubectl get svc

```

### Create Standalone with Bloom and GDS
```
# install the simple standalone chart
# populate licenses/gds.license and licenses/bloom.license with actual licenses
./createLicenseSecrets.sh
helm upgrade -i standalone  neo4j/neo4j -f  standalone.yaml
#look at the pods
kubectl get po
#describe the pods
kubectl describe po standalone-0

```
### Create Load Balancer
```

kubectl apply -f standalone-lb.yaml
kubectl get svc 
#might say pending
kubectl describe svc standalone-lb 
#look for errors

```


### Create the cluster
```
helm install server1 neo4j/neo4j --namespace neo4j -f neo4j-core-cluster.yaml
helm install server2 neo4j/neo4j --namespace neo4j -f neo4j-core-cluster.yaml
helm install server3 neo4j/neo4j --namespace neo4j -f neo4j-core-cluster.yaml
```

### Cleanup
To uninstall, execute the following
```
helm uninstall server1 server2 server3
```

To fully remove all data and resources:
```
kubectl delete pvc --all --namespace neo4j
az aks delete --name neo4j-aks-cluster  --resource-group jhair-RG
```


## [3 Primary/node hybrid cluster with 1 Secondary/GDS (3 primary nodes, 1 secondary/GDS)](./hybrid-gds/README.md)
### Pre-req:
- Azure resource group exists

### Create the cluster
Execute ```./scripts/startall.sh```
The script will perform the following:
- Create an AKS cluster (e.g. neo4j-aks-cluster)
- Create a namespace within the AKS cluster (e.g. neo4j-hybrid)
- Create a nodepool within the AKS cluster (e.g. neo4j)
- Install the Neo4j services and pods
- Create load balancers for the core DB and the GDS node

### Cleanup
Execute ./scripts/stopall.sh

## [Deploy a single Neo4j cluster across multiple AKS clusters](./neo4j-cluster-across-multiple-AKS/README.md)
Neo4j docs - https://neo4j.com/docs/operations-manual/current/kubernetes/multi-dc-cluster/aks/
### Pre-req:
- Azure resource group exists
