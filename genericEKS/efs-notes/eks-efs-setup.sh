helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update
helm upgrade --install aws-efs-csi-driver --namespace kube-system aws-efs-csi-driver/aws-efs-csi-driver
export CLUSTER_NAME=drose-cluster2
export AWS_REGION=us-east-2
oidc_id=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
echo $oidc_id
echo look for the oicd in the cluster
eksctl utils update-cluster-logging --enable-types={all} --region=$AWS_REGION --cluster=$CLUSTER_NAME

aws iam list-open-id-connect-providers | grep $oidc_id
aws iam create-policy --policy-name $CLUSTER_NAME-efs-policy --policy-document file://efs-iam-policy-example.JSON

export policy_arn=arn:aws:iam::766746056086:policy/drose-cluster2-efs-policy

eksctl create iamserviceaccount --name $CLUSTER_NAME-efs-sa --namespace default --cluster $CLUSTER_NAME --role-name $CLUSTER_NAME"-efs-role"  --attach-policy-arn $policy_arn
export EFS_SA="drose-cluster2-efs-sa"
aws iam get-role --role-name $CLUSTER_NAME"-efs-role" --query Role.AssumeRolePolicyDocument
aws iam list-attached-role-policies --role-name $CLUSTER_NAME"-efs-role"


aws iam get-policy --policy-arn $policy_arn
aws iam get-policy-version --policy-arn $policy_arn --version-id v1


export EFS_SECURITY_GROUP=$CLUSTER_NAME"-efs-security-group"
export EFS_SECURITY_GROUP_DESC="Security Group for my Interactive EFS"

export vpc_id=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)
echo VPC ID: $vpc_id
export cidr_range=$(aws ec2 describe-vpcs \
    --vpc-ids $vpc_id \
    --query "Vpcs[].CidrBlock" \
    --output text)
echo CIDR: $cidr_range

export security_group_id=$(aws ec2 create-security-group \
    --group-name $EFS_SECURITY_GROUP \
    --description "$EFS_SECURITY_GROUP_DESC" \
    --vpc-id $vpc_id \
    --output text)
echo SecurityGroupID: $security_group_id

export security_group_id=sg-08e48f7ade255f99f

export auth_security_group_ingress=$(aws ec2 authorize-security-group-ingress \
    --group-id $security_group_id \
    --protocol tcp \
    --port 2049 \
    --cidr $cidr_range)
echo $auth_security_group_ingress



# us-east-2a      10.10.64.0/19   subnet-0c6c3b8d8f80a3522 eksctl-drose-cluster2-cluster/SubnetPublicUSEAST2A
# us-east-2b      10.10.0.0/19    subnet-0fb3c7f734ea25e35 eksctl-drose-cluster2-cluster/SubnetPublicUSEAST2B
# us-east-2c      10.10.32.0/19   subnet-0caad94f3693bae8a eksctl-drose-cluster2-cluster/SubnetPublicUSEAST2C
#
# us-east-2a      10.10.160.0/19  subnet-0a314fd1814f79a41 eksctl-drose-cluster2-cluster/SubnetPrivateUSEAST2A
# us-east-2b      10.10.96.0/19   subnet-04852940fd3b04f16 eksctl-drose-cluster2-cluster/SubnetPrivateUSEAST2B
# us-east-2c      10.10.128.0/19  subnet-0c0249d8f4cd53f2f eksctl-drose-cluster2-cluster/SubnetPrivateUSEAST2C

export us_east_2a=subnet-0a314fd1814f79a41
export us_east_2b=subnet-04852940fd3b04f16
export us_east_2c=subnet-0c0249d8f4cd53f2f


aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[*].{SubnetId: SubnetId,AvailabilityZone: AvailabilityZone,CidrBlock: CidrBlock}' \
    --output table
export FileSystemId=$(aws efs create-file-system \
    --region $AWS_REGION \
    --performance-mode generalPurpose \
    --query 'FileSystemId' \
    --output text)

export FileSystemId=fs-0fbbd8f2d65d482d7

export east2cmount=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2c\
    --security-groups $security_group_id )
echo east2cmount1: $east2cmount


export east2bmount=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2b\
    --security-groups $security_group_id )
echo east2bmount1: $east2bmount


export east2amount=$( aws efs create-mount-target \
     --file-system-id $FileSystemId \
     --subnet-id $us_east_2a \
     --security-groups $security_group_id )
 echo east2amount: $east2amount

 kk apply -f storageclass/sc-efs-neo4j.yaml
 kk apply -f pv/neomedpv1.yaml
 kk apply -f pvc/efs-med-pvc1.yaml

 helm upgrade -i small1 neo4j/neo4j-cluster-core -f core1small.yaml
