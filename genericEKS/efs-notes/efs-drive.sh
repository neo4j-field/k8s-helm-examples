export CLUSTER_NAME=drose-cluster1
export EFS_SECURITY_GROUP=drose-cluster-efs-policy
export EFS_SECURITY_GROUP_DESC="Security Group for my Interactive EFS"
export AWS_REGION=us-east-2
export vpc_id=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)
echo VPC ID: $vpc_id
cidr_range=$(aws ec2 describe-vpcs \
    --vpc-ids $vpc_id \
    --query "Vpcs[].CidrBlock" \
    --output text)
echo CIDR: $cidr_range

security_group_id=$(aws ec2 create-security-group \
    --group-name $EFS_SECURITY_GROUP \
    --description "$EFS_SECURITY_GROUP_DESC" \
    --vpc-id $vpc_id \
    --output text)
echo SecurityGroupID: $security_group_id
auth_security_group_ingress=$(aws ec2 authorize-security-group-ingress \
    --group-id $security_group_id \
    --protocol tcp \
    --port 2049 \
    --cidr $cidr_range)
echo $auth_security_group_ingress
aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[*].{SubnetId: SubnetId,AvailabilityZone: AvailabilityZone,CidrBlock: CidrBlock}' \
    --output table
