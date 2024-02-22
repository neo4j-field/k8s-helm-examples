# Deploy a single Neo4j cluster across multiple AKS clusters
Neo4j docs - https://neo4j.com/docs/operations-manual/current/kubernetes/multi-dc-cluster/aks/

## Pre-req:
- Azure resource group exists

### Create the network and AKS clusters
- In resource group, create an Azure Virtual Network (VNet)
    - ```az network vnet create  --name my-VNet  --resource-group jhair-RG  --address-prefixes 10.30.0.0/16```
- Add four subnets to the VNet. Will be used to deploy on each AKS cluster
    - ```az network vnet subnet create -g jhair-RG  --vnet-name my-VNet -n subnet1 --address-prefixes 10.30.1.0/24```
    - ```az network vnet subnet create -g jhair-RG --vnet-name my-VNet -n subnet2 --address-prefixes 10.30.2.0/24```
    - ```az network vnet subnet create -g jhair-RG --vnet-name my-VNet -n subnet3 --address-prefixes 10.30.3.0/24```
    - ```az network vnet subnet create -g jhair-RG --vnet-name my-VNet -n subnet4 --address-prefixes 10.30.4.0/24```
- Create AKS cluster 1
    - Get subscription ID of subnet1
        - ```az network vnet subnet show -g jhair-RG  --vnet-name my-VNet -n subnet1 --output json | grep .id```
    - Create cluster 1
        - ```az aks create --name jhair-neo4j-aks-cluster1 --node-count=5 --zones 1 --vnet-subnet-id "/subscriptions/2e471c7c-93ee-4af3-ae46-95fecbad4355/resourceGroups/jhair-RG/providers/Microsoft.Network/virtualNetworks/my-VNet/subnets/subnet1" -g jhair-RG```
- Create AKS cluster 2
    - Get subscription ID of subnet2
        - ```az network vnet subnet show -g jhair-RG  --vnet-name my-VNet -n subnet2 --output json | grep .id```
    - Create cluster 2
        - ```az aks create --name jhair-neo4j-aks-cluster2 --node-count=5 --zones 1 --vnet-subnet-id "/subscriptions/2e471c7c-93ee-4af3-ae46-95fecbad4355/resourceGroups/jhair-RG/providers/Microsoft.Network/virtualNetworks/my-VNet/subnets/subnet2" -g jhair-RG```
- Create AKS cluster 3
    - Get subscription ID of subnet3
        - ```az network vnet subnet show -g jhair-RG  --vnet-name my-VNet -n subnet3 --output json | grep .id```
    - Create cluster 3
        - ```az aks create --name jhair-neo4j-aks-cluster3 --node-count=5 --zones 1 --vnet-subnet-id "/subscriptions/2e471c7c-93ee-4af3-ae46-95fecbad4355/resourceGroups/jhair-RG/providers/Microsoft.Network/virtualNetworks/my-VNet/subnets/subnet3" -g jhair-RG```

### Install Neo4j on within each AKS cluster
- Configure kubectl to use AKS clusters
    - ```az aks get-credentials --name jhair-neo4j-aks-cluster1 --admin -g jhair-RG```
    - ```az aks get-credentials --name jhair-neo4j-aks-cluster2 --admin -g jhair-RG```
    - ```az aks get-credentials --name jhair-neo4j-aks-cluster3 --admin -g jhair-RG```

- Install Neo4j on each AKS cluster
    - Create 3 separate yaml files for each server within jhair-neo4j-aks-cluster1
    - ```kubectl config use-context jhair-neo4j-aks-cluster1-admin```
    - ```helm install server1 neo4j/neo4j -f Multi-AKS-cluster1.yaml```
    - ```kubectl config use-context jhair-neo4j-aks-cluster2-admin```
    - ```helm install server2 neo4j/neo4j -f Multi-AKS-cluster2.yaml```
    - ```kubectl config use-context jhair-neo4j-aks-cluster3-admin```
    - ```helm install server3 neo4j/neo4j -f Multi-AKS-cluster3.yaml```

### Cleanup
To fully remove all data and resources:
```
az aks delete --name neo4j-aks-cluster1  --resource-group jhair-RG
az aks delete --name neo4j-aks-cluster2  --resource-group jhair-RG
az aks delete --name neo4j-aks-cluster3  --resource-group jhair-RG
```