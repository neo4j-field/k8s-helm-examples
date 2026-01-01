# https://docs.azure.cn/en-us/aks/configure-azure-cni-dynamic-ip-allocation

export RESOURCE_GROUP_NAME="multi-region-rg"
export VNET_NAME_CENTRAL="multi-region-central-vnet"
export VNET_NAME_EAST="multi-region-east-vnet"
export VNET_NAME_WEST="multi-region-west-vnet"
export LOCATION_CENTRAL="centralus"
export LOCATION_EAST="eastus"
export LOCATION_WEST="westus"
export SUBNET_NAME_CENTRAL_CLUSTER="multi-region-central-cluster"
export SUBNET_NAME_CENTRAL_1="multi-region-central-subnet1"
export SUBNET_NAME_CENTRAL_2="multi-region-central-subnet2"
export SUBNET_NAME_CENTRAL_3="multi-region-central-subnet3"
export SUBNET_NAME_CENTRAL_GW="multi-region-central-subnet-gw"

export SUBNET_NAME_EAST_CLUSTER="multi-region-east-cluster"
export SUBNET_NAME_EAST_1="multi-region-east-subnet1"
export SUBNET_NAME_EAST_2="multi-region-east-subnet2"
export SUBNET_NAME_EAST_3="multi-region-east-subnet3"
export SUBNET_NAME_EAST_GW="multi-region-east-subnet-gw"

export SUBNET_NAME_CLUSTER_CENTRAL="mrc-central"
export SUBNET_NAME_CLUSTER_EAST="mrc-east"
export SUBSCRIPTION_ID="70bb2c8c-6c76-47c0-b6c9-82f0204f30ac"
export TAGS="owner=drose"

export AKS_CLUSTER_EAST="multi-region-east-cluster"
export AKS_CLUSTER_CENTRAL="multi-region-central-cluster"
export AKS_NODE_SYSTEM="Standard_D2as_v6"
export AKS_NODE_COUNT="2"

export NODE_POOL_NAME="neo4jpool1"
export AKS_NODE_USER="Standard_D2as_v6"
export DNS_NAME="drose-private.com"
export SRV_RECORDSET_NAME="cluster-endpoints.multireg"
export SRV_TARGET="multireg.drose-private.com"

export VNET_LINK_CENTRAL="vnet-link-central"
export AAD_GROUP_ID="117c5f89-6a02-459d-b2a5-f74029e2250c"
export AAD_TENANT_ID="70bb2c8c-6c76-47c0-b6c9-82f0204f30ac"

 

# Create the resource group
az group create --name $RESOURCE_GROUP_NAME --location $LOCATION --tags $TAGS



# Create our two subnet network 
az network vnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --location $LOCATION_CENTRAL --name $VNET_NAME_CENTRAL --address-prefixes 10.0.0.0/16 -o none 
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME_CENTRAL --name $SUBNET_NAME_CENTRAL_CLUSTER --address-prefixes 10.0.16.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME_CENTRAL --name $SUBNET_NAME_CENTRAL_1 --address-prefixes 10.0.32.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME_CENTRAL --name $SUBNET_NAME_CENTRAL_2 --address-prefixes 10.0.48.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME_CENTRAL --name $SUBNET_NAME_CENTRAL_3 --address-prefixes 10.0.64.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME_CENTRAL --name $SUBNET_NAME_CENTRAL_GW --address-prefixes 10.0.80.0/20 -o none

az network vnet create --resource-group $RESOURCE_GROUP_NAME --location $LOCATION_EAST --name $VNET_NAME_EAST --address-prefixes 10.0.0.0/16 -o none 
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --vnet-name $VNET_NAME_EAST --name $SUBNET_NAME_CLUSTER_EAST --address-prefixes 10.0.0.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --vnet-name $VNET_NAME_EAST --name $SUBNET_NAME_EAST_1 --address-prefixes 10.0.16.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --vnet-name $VNET_NAME_EAST --name $SUBNET_NAME_EAST_2 --address-prefixes 10.0.32.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --vnet-name $VNET_NAME_EAST --name $SUBNET_NAME_EAST_3 --address-prefixes 10.0.48.0/20 -o none
az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --vnet-name $VNET_NAME_EAST --name $SUBNET_NAME_EAST_GW --address-prefixes 10.0.64.0/20 -o none




az aks create  --tags $TAGS \
    --name $AKS_CLUSTER_CENTRAL \
    --resource-group $RESOURCE_GROUP_NAME \
    --location $LOCATION_CENTRAL \
    --auto-upgrade-channel stable \
    --os-sku Ubuntu \
    --node-vm-size $AKS_NODE_SYSTEM \
    --node-count $AKS_NODE_COUNT \
    --nodepool-name agentpool\
    --nodepool-tags $TAGS \
    --max-pods 250 \
    --network-plugin azure \
    --service-cidr 10.0.0.0/20 \
    --dns-service-ip 10.0.0.10 \
    --vnet-subnet-id /subscriptions/70bb2c8c-6c76-47c0-b6c9-82f0204f30ac/resourceGroups/multi-region-rg/providers/Microsoft.Network/virtualNetworks/multi-region-central-vnet/subnets/mrc-centralus-vnet-1 \
    --pod-subnet-id /subscriptions/70bb2c8c-6c76-47c0-b6c9-82f0204f30ac/resourceGroups/multi-region-rg/providers/Microsoft.Network/virtualNetworks/multi-region-central-vnet/subnets/mrc-centralus-pod-1 \
    --enable-addons monitoring \
    --enable-workload-identity --enable-oidc-issuer \
    --enable-syslog \
    --enable-azure-rbac --enable-aad  \
    --generate-ssh-keys

    az aks get-credentials --name $AKS_CLUSTER_CENTRAL --admin --resource-group $RESOURCE_GROUP_NAME

    #az aks delete --resource-group $RESOURCE_GROUP_NAME --name $AKS_CLUSTER_CENTRAL

az aks update --resource-group $RESOURCE_GROUP_NAME --name $AKS_CLUSTER_CENTRAL--enable-aad --aad-admin-group-object-ids $AAD_GROUP_ID --aad-tenant-id $AAD_TENANT_ID

    az aks nodepool add --cluster-name $AKS_CLUSTER_CENTRAL \
    --resource-group $RESOURCE_GROUP_NAME \
    --nodepool-name $NODE_POOL_NAME \
    --max-pods 250 \
    --node-count 3 \
    --enable-cluster-autoscaler \
    --tags $TAGS \
    --mode User \
    --os-sku Ubuntu \
    --max-surge 1 \
    --max-count  6 \
    --min-count 3 \
    --node-vm-size $AKS_NODE_USER \
    --zones 1 2 \
    --vnet-subnet-id /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/virtualNetworks/$VNET_NAME_CENTRAL/subnets/$SUBNET_NAME_CENTRAL_2 \
    --pod-subnet-id /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/virtualNetworks/$VNET_NAME_CENTRAL/subnets/$SUBNET_NAME_CENTRAL_3

https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/azure-private-dns.md

az network private-dns zone create --resource-group $RESOURCE_GROUP_NAME \
    --name $DNS_NAME

export SRV_RECORDSET_NAME="cluster-endpoints.multireg"
export SRV_TARGET="multireg.drose-private.com"

az network private-dns record-set srv create --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --name $SRV_RECORDSET_NAME

    az network private-dns record-set srv show --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --name $SRV_RECORDSET_NAME



    az network private-dns record-set srv add-record --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --record-set-name ${SRV_RECORDSET_NAME} \
    --target lb1.${SRV_TARGET} -r 6000 -p 10 -w 10

    az network private-dns record-set srv add-record --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --record-set-name ${SRV_RECORDSET_NAME} \
    --target lb2.${SRV_TARGET} -r 6000 -p 10 -w 10   

    az network private-dns record-set srv add-record --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --record-set-name ${SRV_RECORDSET_NAME} \
    --target lb3.${SRV_TARGET} -r 6000 -p 10 -w 10   

    export SRV_RECORDSET_NAME="discovery-endpoints.multireg"

    az network private-dns record-set srv create --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --name $SRV_RECORDSET_NAME

    az network private-dns record-set srv show --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --name $SRV_RECORDSET_NAME

     az network private-dns record-set srv add-record --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --record-set-name ${SRV_RECORDSET_NAME} \
    --target lb1.${SRV_TARGET} -r 5000 -p 10 -w 10

    az network private-dns record-set srv add-record --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --record-set-name ${SRV_RECORDSET_NAME} \
    --target lb2.${SRV_TARGET} -r 5000 -p 10 -w 10   

       az network private-dns record-set srv add-record --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --record-set-name ${SRV_RECORDSET_NAME} \
    --target lb3.${SRV_TARGET} -r 5000 -p 10 -w 10   
    
    
   
    az network private-dns link vnet create --resource-group $RESOURCE_GROUP_NAME \
    --zone-name $DNS_NAME \
    --virtual-network $VNET_NAME_CENTRAL \
    --name $VNET_LINK_CENTRAL \
    --tags $TAGS \
    --registration-enabled false


    export KEYVAULT_NAME="drose-multi-region-kv"

   az keyvault create --location $LOCATION_CENTRAL --name $KEYVAULT_NAME \
    --tags $TAGS  --resource-group $RESOURCE_GROUP_NAME \
    --enable-rbac-authorization true \
    --public-network-access enabled --bypass AzureServices \
    --enabled-for-deployment true \
    --sku standard

  export KEYVAULT_ID="/subscriptions/70bb2c8c-6c76-47c0-b6c9-82f0204f30ac/resourceGroups/multi-region-rg/providers/Microsoft.KeyVault/vaults/drose-multi-region-kv"

az keyvault role assignment create --id $KEYVAULT_ID  \
 --role "Key Vault Administrator" \
  --assignee david.rosenblum@neo4j.com \
  --scope "/" \
  --name ${KEYVAULT_NAME}-admin

az keyvault key create \
    --exportable true \
    --size 2048 \
    --kty RSA \
    --name  ${SP_NAME}-cert \
    --vault-name $KEYVAULT_NAME \
    --tags $TAGS \
    --ops export
    


    export SP_NAME="drose-multi-region-sp1"
    export CERT_NAME="drose-multi-region-sp-cert"

    export SP_ID=`az ad sp create-for-rbac --name $SP_NAME \
    --keyvault $KEYVAULT_NAME \
    --cert $CERT_NAME --query "appId" --output tsv`

    export OWNER_UPN="david.rosenblum@neo4j.com"

    export OWNER_ID=`az ad user list --upn $OWNER_UPN --query "[].id" --output tsv`

    export SP_ID=`az ad sp list --display-name $SP_NAME  --output tsv --query "[].id"`

    az ad app owner add  --id $SP_ID  --owner-object-id $OWNER_ID



    az aks create --tags owner=drose --name multi-region-central-cluster --resource-group multi-region-rg --location centralus --auto-upgrade-channel stable --os-sku Ubuntu --node-vm-size Standard_D2as_v6 --node-count 2 --nodepool-name systempool1 --nodepool-tags owner=drose --min-count 1 --max-count 4 --enable-cluster-autoscaler --max-pods 250 --network-plugin azure --service-cidr 10.0.0.0/20 --dns-service-ip 10.0.0.10 --vnet-subnet-id /subscriptions/70bb2c8c-6c76-47c0-b6c9-82f0204f30ac/resourceGroups/multi-region-rg/providers/Microsoft.Network/virtualNetworks/multi-region-central-vnet/subnets/mrc-centralus-vnet-1 --pod-subnet-id /subscriptions/70bb2c8c-6c76-47c0-b6c9-82f0204f30ac/resourceGroups/multi-region-rg/providers/Microsoft.Network/virtualNetworks/multi-region-central-vnet/subnets/mrc-centralus-pod-1 --enable-addons monitoring --enable-workload-identity --enable-oidc-issuer --enable-syslog --enable-oidc-issuer --zones 1 2 3 --enable-azure-rbac --enable-aad --generate-ssh-keys



    export VNET_NAME_EAST="multi-region-east-vnet"
    export VNET_NAME_CENTRAL="multi-region-central-vnet"
    export PEERING_CENTRAL_TO_EAST="vnet-central-to-east"
    export PEERING_EAST_TO_CENTRAL="vnet-east-to-central"

    
"## Create peering from vnet-1 to vnet-2. ##
az network vnet peering create --name $PEERING_CENTRAL_TO_EAST --vnet-name $VNET_NAME_CENTRAL --remote-vnet $VNET_NAME_EAST  --resource-group $RESOURCE_GROUP_NAME --allow-vnet-access --allow-forwarded-traffic

## Create peering from vnet-2 to vnet-1. ##
az network vnet peering create --name $PEERING_EAST_TO_CENTRAL --vnet-name $VNET_NAME_EAST --remote-vnet $VNET_NAME_CENTRAL --resource-group $RESOURCE_GROUP_NAME --allow-vnet-access --allow-forwarded-traffic