export CLUSTER_NAME=my-cluster3
export EFS_SECURITY_GROUP=myEFSSecurityGroup
export EFS_SECURITY_GROUP_DESC="Security Group for my Interactive EFS"
export AWS_REGION=us-east-2
export SecurityGroupID=sg-02a6322f508fe33d0
export vpc_id=vpc-04d71c8f79672d274
export cidr=10.10.0.0/16
#export FileSystemId=arn:aws:elasticfilesystem:us-east-1:766746056086:file-system/fs-0bafc86f5cdd44438
#export FileSystemId=fs-082acc68861bced71

# --------------------------------------------------------------------
# |                          DescribeSubnets                         |
# +------------------+------------------+----------------------------+
# | AvailabilityZone |    CidrBlock     |         SubnetId           |
# +------------------+------------------+----------------------------+
# |  us-east-2b      |  10.10.160.0/19  |  subnet-05614c07a91458d36  |
# |  us-east-2a      |  10.10.96.0/19   |  subnet-09abfd59a4da1e9b6  |
# |  us-east-2c      |  10.10.32.0/19   |  subnet-04981a8b447f003cd  |
# |  us-east-2a      |  10.10.0.0/19    |  subnet-0e771fd8e031e1eff  |
# |  us-east-2b      |  10.10.64.0/19   |  subnet-097abdc2e1ae465c7  |
# |  us-east-2c      |  10.10.128.0/19  |  subnet-0db6abbb3fd84f52b  |
# +------------------+------------------+----------------------------+



export us_east_2b_1=subnet-05614c07a91458d36
export us_east_2a_1=subnet-09abfd59a4da1e9b6
export us_east_2c_1=subnet-04981a8b447f003cd
export us_east_2a_2=subnet-0e771fd8e031e1eff
export us_east_2b_2=subnet-097abdc2e1ae465c7
export us_east_2c_2=subnet-0db6abbb3fd84f52b


aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[*].{SubnetId: SubnetId,AvailabilityZone: AvailabilityZone,CidrBlock: CidrBlock}' \
    --output table
export FileSystemId=$(aws efs create-file-system \
    --region $AWS_REGION \
    --performance-mode generalPurpose \
    --query 'FileSystemId' \
    --output text)

#export FileSystemId=fs-0ef49a5019963a88b
export FileSystemId=fs-0e1bf669c3f0ff8f7
echo FileSystemId: $FileSystemId
echo sleeping 30 seconds to let file system setup finish
sleep 30
east2amount1=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2a_1 \
    --security-groups $security_group_id )
echo east2amount1: $east2amount1
# east2amount: {
#     "OwnerId": "766746056086",
#     "MountTargetId": "fsmt-000157d8e84156880",
#     "FileSystemId": "fs-0f3a6d2fab9803fe9",
#     "SubnetId": "subnet-016885b117f33b5b9",
#     "LifeCycleState": "creating",
#     "IpAddress": "10.10.55.159",
#     "NetworkInterfaceId": "eni-07b0be360077e62b7",
#     "AvailabilityZoneId": "use2-az1",
#     "AvailabilityZoneName": "us-east-2a",
#     "VpcId": "vpc-080ee92b867197f48"
# }
sleep 3
export east2bmount1=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2b_1\
    --security-groups $security_group_id )
echo east2bmount1: $east2bmount1

# east2bmount: {
#     "OwnerId": "766746056086",
#     "MountTargetId": "fsmt-0082f5881246b46cc",
#     "FileSystemId": "fs-0f3a6d2fab9803fe9",
#     "SubnetId": "subnet-03ddcecaa735781f7",
#     "LifeCycleState": "creating",
#     "IpAddress": "10.10.11.106",
#     "NetworkInterfaceId": "eni-0dbda98a2ab7a9c07",
#     "AvailabilityZoneId": "use2-az2",
#     "AvailabilityZoneName": "us-east-2b",
#     "VpcId": "vpc-080ee92b867197f48"

export east2cmount1=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2c_1\
    --security-groups $security_group_id )
echo east2cmount1: $east2cmount1
sleep 3
# east2cmount: {
#     "OwnerId": "766746056086",
#     "MountTargetId": "fsmt-0e31583fb9f314a0e",
#     "FileSystemId": "fs-0f3a6d2fab9803fe9",
#     "SubnetId": "subnet-0af25bb1c9af05aa6",
#     "LifeCycleState": "creating",
#     "IpAddress": "10.10.87.23",
#     "NetworkInterfaceId": "eni-027bd1263325419b4",
#     "AvailabilityZoneId": "use2-az3",
#     "AvailabilityZoneName": "us-east-2c",
#     "VpcId": "vpc-080ee92b867197f48"

east2amount2=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2a_2 \
    --security-groups $security_group_id )
echo east2amount2: $east2amount2
sleep 3
# east2amount: {
#     "OwnerId": "766746056086",
#     "MountTargetId": "fsmt-000157d8e84156880",
#     "FileSystemId": "fs-0f3a6d2fab9803fe9",
#     "SubnetId": "subnet-016885b117f33b5b9",
#     "LifeCycleState": "creating",
#     "IpAddress": "10.10.55.159",
#     "NetworkInterfaceId": "eni-07b0be360077e62b7",
#     "AvailabilityZoneId": "use2-az1",
#     "AvailabilityZoneName": "us-east-2a",
#     "VpcId": "vpc-080ee92b867197f48"
# }

export east2bmount2=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2b_2\
    --security-groups $security_group_id )
echo east2bmount2: $east2bmount2
sleep 3
# east2bmount: {
#     "OwnerId": "766746056086",
#     "MountTargetId": "fsmt-0082f5881246b46cc",
#     "FileSystemId": "fs-0f3a6d2fab9803fe9",
#     "SubnetId": "subnet-03ddcecaa735781f7",
#     "LifeCycleState": "creating",
#     "IpAddress": "10.10.11.106",
#     "NetworkInterfaceId": "eni-0dbda98a2ab7a9c07",
#     "AvailabilityZoneId": "use2-az2",
#     "AvailabilityZoneName": "us-east-2b",
#     "VpcId": "vpc-080ee92b867197f48"

export east2cmount2=$( aws efs create-mount-target \
    --file-system-id $FileSystemId \
    --subnet-id $us_east_2c_2\
    --security-groups $security_group_id )
echo east2cmount2: $east2cmount2
# east2cmount: {
#     "OwnerId": "766746056086",
#     "MountTargetId": "fsmt-0e31583fb9f314a0e",
#     "FileSystemId": "fs-0f3a6d2fab9803fe9",
#     "SubnetId": "subnet-0af25bb1c9af05aa6",
#     "LifeCycleState": "creating",
#     "IpAddress": "10.10.87.23",
#     "NetworkInterfaceId": "eni-027bd1263325419b4",
#     "AvailabilityZoneId": "use2-az3",
#     "AvailabilityZoneName": "us-east-2c",
#     "VpcId": "vpc-080ee92b867197f48"
