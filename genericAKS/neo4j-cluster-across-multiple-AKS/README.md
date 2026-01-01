# Deploy a single Neo4j cluster across multiple AKS clusters
Neo4j docs - https://neo4j.com/docs/operations-manual/current/kubernetes/multi-dc-cluster/aks/

## Pre-req:
- Azure resource group exists

### Create the network and AKS clusters
- In resource group, create an Azure Virtual Network (VNet)
    ```bash
    az network vnet create --name jhair-VNet --resource-group jhair-RG \
    --location eastus --address-prefixes 10.30.0.0/16
    ```
- Add subnets to the VNet (1 for each AKS cluster)
    ```bash
    az network vnet subnet create -g jhair-RG  --vnet-name jhair-VNet -n subnet1 --address-prefixes 10.30.1.0/24
    az network vnet subnet create -g jhair-RG --vnet-name jhair-VNet -n subnet2 --address-prefixes 10.30.2.0/24
    az network vnet subnet create -g jhair-RG --vnet-name jhair-VNet -n subnet3 --address-prefixes 10.30.3.0/24
    ```
- Create AKS cluster 1 - EastUS
    ```bash
    #Get subscription ID of subnet1
    SUB_ID1=`az network vnet subnet show -g jhair-RG --vnet-name jhair-VNet -n subnet1 --output tsv --query "id"`
    az aks create --name jhair-neo4j-aks-cluster1 --resource-group jhair-RG \
    --location eastus --auto-upgrade-channel stable \
    --vnet-subnet-id $SUB_ID1 --zones 1 2 3 \
    --enable-cluster-autoscaler --min-count 1 --max-count 4 --enable-addons monitoring

    # Create a 'User' nodepool for applications
    az aks nodepool add --cluster-name jhair-neo4j-aks-cluster1 --resource-group jhair-RG \
    --nodepool-name neo4j --node-count 4 \
    --enable-cluster-autoscaler --min-count 1 --max-count 6 \
    --labels "nodegroup=neo4j" \
    --node-vm-size Standard_E16as_v5
    ```
- Create AKS cluster 2 - WestUS
    ```bash
    #Get subscription ID of subnet2
    SUB_ID2=`az network vnet subnet show -g jhair-RG  --vnet-name jhair-VNet -n subnet2 --output tsv --query "id"`
    az aks create --name jhair-neo4j-aks-cluster2 --resource-group jhair-RG \
    --location eastus --auto-upgrade-channel stable \
    --vnet-subnet-id $SUB_ID1 --zones 1 2 3 \
    --enable-cluster-autoscaler --min-count 1 --max-count 4 --enable-addons monitoring

    # Create a 'User' nodepool for applications
    az aks nodepool add --cluster-name jhair-neo4j-aks-cluster2 --resource-group jhair-RG \
    --nodepool-name neo4j --node-count 4 \
    --enable-cluster-autoscaler --min-count 1 --max-count 6 \
    --labels "nodegroup=neo4j" \
    --node-vm-size Standard_E16as_v5
    ```
- Create AKS cluster 3 - CentralUS
    ```bash
    # Get subscription ID of subnet3
    SUB_ID3=`az network vnet subnet show -g jhair-RG  --vnet-name jhair-VNet -n subnet3 --output tsv --query "id"`
    az aks create --name jhair-neo4j-aks-cluster3 --resource-group jhair-RG \
    --location eastus --auto-upgrade-channel stable \
    --vnet-subnet-id $SUB_ID3 --zones 1 2 3 \
    --enable-cluster-autoscaler --min-count 1 --max-count 4 --enable-addons monitoring

    # Create a 'User' nodepool for applications
    az aks nodepool add --cluster-name jhair-neo4j-aks-cluster3 --resource-group jhair-RG \
    --nodepool-name neo4j --node-count 4 \
    --enable-cluster-autoscaler --min-count 1 --max-count 6 \
    --labels "nodegroup=neo4j" \
    --node-vm-size Standard_E16as_v5
    ```

### Install Neo4j on within each AKS cluster
- Configure kubectl to use AKS clusters
    ```bash
    az aks get-credentials --name jhair-neo4j-aks-cluster1 --admin -g jhair-RG --overwrite-existing
    az aks get-credentials --name jhair-neo4j-aks-cluster2 --admin -g jhair-RG --overwrite-existing
    az aks get-credentials --name jhair-neo4j-aks-cluster3 --admin -g jhair-RG --overwrite-existing
    ```

- Install Neo4j using 3 separate yaml files for each server per AKS cluster
    ```bash
    kubectl config use-context jhair-neo4j-aks-cluster1-admin
    helm install server1 neo4j/neo4j -f Multi-AKS-cluster1.yaml

    kubectl config use-context jhair-neo4j-aks-cluster2-admin
    helm install server2 neo4j/neo4j -f Multi-AKS-cluster2.yaml

    kubectl config use-context jhair-neo4j-aks-cluster3-admin
    helm install server3 neo4j/neo4j -f Multi-AKS-cluster3.yaml
    ```

### Cleanup
To fully remove all data and resources:
```sh
az aks delete --name jhair-neo4j-aks-cluster1  --resource-group jhair-RG --no-wait --yes
az aks delete --name jhair-neo4j-aks-cluster2  --resource-group jhair-RG --no-wait --yes
az aks delete --name jhair-neo4j-aks-cluster3  --resource-group jhair-RG --no-wait --yes
az network vnet delete --name jhair-VNet --resource-group jhair-RG
```