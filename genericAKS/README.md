# AKS deployment examples

## Pre-requisites
- Verify that you have a Resource Group
    - ```az group create --name jhair-RG```
- Set defaults
    - ```az configure --defaults group=jhair-RG```
    - ```az configure --defaults location=eastus```
- List defaults
    - ```az configure -l```


## [Neo4j 3 node cluster within 1 AKS cluster](neo4j-core-cluster.yaml)
Neo4j docs - https://neo4j.com/docs/operations-manual/current/kubernetes/quickstart-cluster/
### Pre-req:
- Azure resource group exists
- AKS cluster exists (e.g. neo4j-aks-cluster)
- Namespace within the AKS cluster exists (e.g neo4j)

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
