#!/bin/bash

get_set_rg(){ 
    RESOURCE_GROUP_NAME=$1
    LOCATION=$2
    TAGS=$3
    group_exists=`az group exists --resource-group $1`
    if [[ -z "group_exists" ]]; then
        echo "Variable is empty"
        exit 1
    else
        #echo $group_exists $1
        if [[ $group_exists == "true" ]]; then
            echo `az group show --name $1 --output tsv --query "id"`
        else
            echo `az group create --name $1 --location $2 --tags $3 --output tsv --query "id"`
        fi
    fi

    
    #az group create --name $1 --location $2 --tags $3
}

get_sp_id(){
    SP_NAME=$1
        
    SP_ID=`az ad sp list --display-name $1  --output tsv --query "[].appId"`
    echo $SP_ID
}    

get-set-vnet() {
    RESOURCE_GROUP_NAME=$1
    LOCATION=$2
    TAGS=$3
    VNET_NAME=$4
    ADDRESS_PREFIXES=$5
    vnet_exists=`az network vnet list --resource-group $RESOURCE_GROUP_NAME --output tsv --query "[?contains(name,'$VNET_NAME')].id"`
    if [[ -z "$vnet_exists" ]]; then
            vnet=`az network vnet create --resource-group $RESOURCE_GROUP_NAME --tags $TAGS --location $LOCATION --name $VNET_NAME --address-prefixes $ADDRESS_PREFIXES --output tsv  --query "newVNet.id" `
            echo $vnet
    else
        echo $vnet_exists
    fi

}

get-set-subnet() {
    RESOURCE_GROUP_NAME=$1
    VNET_NAME=$2
    SUBNET_NAME=$3
    ADDRESS_PREFIXES=$4
    subnet_exists=`az network vnet subnet list --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME --output tsv --query "[?contains(name,'$SUBNET_NAME')].id"`
    if [[ -z "$subnet_exists" ]]; then
            vnet=`az network vnet subnet create --resource-group $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME --name $SUBNET_NAME --address-prefixes $ADDRESS_PREFIXES --output tsv --query "id"`
            echo $vnet
    else
        echo $subnet_exists
    fi

}
get-set-nodepool() {
    RESOURCE_GROUP_NAME=$1
    CLUSTER_NAME=$2
    NODEPOOL_NAME=$3
    AKS_NODE_USER=$4
    VNET_SUBNET=$5
    POD_SUBNET=$6
    TAGS=$7
set -x
    NODEPOOL_TAGS=$TAGS
    MAX_PODS="250"
    aks_name=`az aks list --resource-group $RESOURCE_GROUP_NAME --query "[?contains(name,'$CLUSTER_NAME')].name" --output tsv`
    if [[ -z "$aks_name" ]]; then
        echo ERROR: NO CLUSTER $CLUSTER_NAME
        exit -1
    else
        np_name=`az aks nodepool list --cluster-name $CLUSTER_NAME --resource-group $RESOURCE_GROUP_NAME --query "[?contains(name,'$NODEPOOL_NAME')].name" --output tsv`
        if [[ -z "$np_name" ]]; then
            export nodepool=`az aks nodepool add --cluster-name $CLUSTER_NAME \
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
            --zones 1 2 3 \
            --vnet-subnet-id $VNET_SUBNET \
            --pod-subnet-id $POD_SUBNET`

            echo $nodepool

        else
            echo $np_name   
        fi
        
    fi


}
get-set-aks() {
    set -x
    RESOURCE_GROUP_NAME=$1
    CLUSTER_NAME=$2
    LOCATION=$3
    VNET_SUBNET=$4
    POD_SUBNET=$5
    TAGS=$6

    #does the cluster exist?
    aks_name=`az aks list --resource-group $RESOURCE_GROUP_NAME --query "[?contains(name,'$CLUSTER_NAME')].name" --output tsv`
    if [[ -z "$aks_name" ]]; then
            SERVICE_CIDR="10.0.0.0/20"
            DNS_SERVICE_IP="10.0.0.10"
            NODEPOOL_NAME="systempool1"
            NODEPOOL_TAGS=$TAGS
            MAX_PODS="250"
            NETWORK_PLUGIN="azure"
            OS_SKU="Ubuntu"
            AKS_NODE_SYSTEM="Standard_D2as_v6"
            AKS_NODE_COUNT="2"
            ZONES="1 2 3"
            AAD_GROUP_ID="117c5f89-6a02-459d-b2a5-f74029e2250c"
            AAD_TENANT_ID="70bb2c8c-6c76-47c0-b6c9-82f0204f30ac"
            
            
            
            export aks_name=`az aks create  --tags $TAGS \
            --name $CLUSTER_NAME \
            --resource-group $RESOURCE_GROUP_NAME \
            --location $LOCATION \
            --auto-upgrade-channel stable \
            --os-sku $OS_SKU \
            --node-vm-size $AKS_NODE_SYSTEM \
            --node-count $AKS_NODE_COUNT \
            --nodepool-name $NODEPOOL_NAME \
            --nodepool-tags $TAGS \
            --min-count 1 \
            --max-count 4 \
            --enable-cluster-autoscaler \
            --max-pods $MAX_PODS \
            --network-plugin $NETWORK_PLUGIN \
            --service-cidr $SERVICE_CIDR \
            --dns-service-ip $DNS_SERVICE_IP \
            --vnet-subnet-id $VNET_SUBNET \
            --pod-subnet-id $POD_SUBNET \
            --enable-addons monitoring \
            --enable-workload-identity --enable-oidc-issuer \
            --enable-syslog \
            --zones $ZONES \
            --generate-ssh-keys`

            # --enable-azure-rbac --enable-aad  \


            echo $aks_name
    else
        echo $aks_name
    fi
}

# write a function
fresh(){
   # t stores $1 argument passed to fresh()
   t=$1
   echo "fresh(): \$0 is $0"
   echo "fresh(): \$1 is $1"
   echo "fresh(): \$t is $t"
   echo "fresh(): total args passed to me $#"
   echo "fresh(): all args (\$@) passed to me -\"$@\""
   echo "fresh(): all args (\$*) passed to me -\"$*\""
}
 
# invoke the function with "Tomato" argument
# echo "**** calling fresh() 1st time ****"
# fresh Tomato
 
# # invoke the function with total 3 arguments
# echo "**** calling fresh() 2nd time ****"
# fresh Tomato Onion Paneer

export RESOURCE_GROUP_NAME="multi-region-rg"
export VNET_NAME_CENTRAL="multi-region-central-vnet"
export VNET_NAME_EAST="multi-region-east-vnet"
export VNET_NAME_WEST="multi-region-west-vnet"
export LOCATION_CENTRAL="centralus"
export LOCATION_EAST="eastus"
export LOCATION_WEST="westus"
export SUBNET_MRC="mrc"



export SUBNET_NAME_CLUSTER_CENTRAL="mrc-central"
export SUBNET_NAME_CLUSTER_EAST="mrc-east"
export SUBSCRIPTION_ID="70bb2c8c-6c76-47c0-b6c9-82f0204f30ac"
export TAGS="owner=drose"
export ADDRESS_PREFIX_VNET="10.0.0.0/16"
export ADDRESS_PREFIX_SUBNET="10.0.0.0/20"
export SP_NAME="drose-multi-region-sp1"
export CERT_NAME="drose-multi-region-sp-cert"
export AKS_CLUSTER_CENTRAL="multi-region-central-cluster"
export AKS_CLUSTER_EAST="multi-region-east-cluster"
export AKS_NODE_SYSTEM="Standard_D2as_v6"
export AKS_NODE_COUNT="2"
export NODE_POOL_NAME="neo4jpool1"
export AKS_NODE_USER="Standard_D2as_v6"
export AAD_GROUP_ID="117c5f89-6a02-459d-b2a5-f74029e2250c"
export AAD_TENANT_ID="70bb2c8c-6c76-47c0-b6c9-82f0204f30ac"



export RG_ID=`get_set_rg ${RESOURCE_GROUP_NAME} $LOCATION_CENTRAL $TAGS "10.0.0.0/16"`
echo Resource ID = $RG_ID
sleep 5

export SP_ID=`get_sp_id $SP_NAME `
echo Svc Princ ID = $SP_ID

export VNET_ID=`get-set-vnet $RESOURCE_GROUP_NAME $LOCATION_EAST $TAGS $VNET_NAME_EAST $ADDRESS_PREFIX_VNET`
echo vnet ID= $VNET_ID

export SUBNET_NUMBER=1
export SUBNET_VNET_1=`get-set-subnet $RESOURCE_GROUP_NAME $VNET_NAME_EAST ${SUBNET_MRC}"-"${LOCATION_EAST}"-vnet-"${SUBNET_NUMBER} "10.0.16.0/20"`
echo subnet vnet1= $SUBNET_VNET_1
export SUBNET_POD_1=`get-set-subnet $RESOURCE_GROUP_NAME $VNET_NAME_EAST ${SUBNET_MRC}"-"${LOCATION_EAST}"-pod-"${SUBNET_NUMBER} "10.0.32.0/20"`
echo subnet POD1= $SUBNET_POD_1
export SUBNET_NUMBER=2
export SUBNET_VNET_2=`get-set-subnet $RESOURCE_GROUP_NAME $VNET_NAME_EAST ${SUBNET_MRC}"-"${LOCATION_EAST}"-vnet-"${SUBNET_NUMBER} "10.0.48.0/20"`
echo subnet VNET2= $SUBNET_VNET_2
export SUBNET_POD_2=`get-set-subnet $RESOURCE_GROUP_NAME $VNET_NAME_EAST ${SUBNET_MRC}"-"${LOCATION_EAST}"-pod-"${SUBNET_NUMBER} "10.0.64.0/20"`
echo subnet POD2= $SUBNET_POD_2
export aks_return=`get-set-aks $RESOURCE_GROUP_NAME $AKS_CLUSTER_EAST $LOCATION_EAST $SUBNET_VNET_1 $SUBNET_POD_1 $TAGS`
echo $aks_return
# RESOURCE_GROUP_NAME=$1
#     CLUSTER_NAME=$2
#     NODEPOOL_NAME=$3
#     $AKS_NODE_USER=$4
#     VNET_SUBNET=$5
#     POD_SUBNET=$6
#     TAGS=$7
export pool_return=`get-set-nodepool $RESOURCE_GROUP_NAME $AKS_CLUSTER_EAST $NODE_POOL_NAME $AKS_NODE_USER $SUBNET_VNET_2 $SUBNET_POD_2 $TAGS`
echo $pool_return
