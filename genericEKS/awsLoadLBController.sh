eksctl create iamserviceaccount \
  --cluster=drose-highlander-green \
  --namespace=kube-system \
  --name=aws-load-balancer-green-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --region us-east-2 \
  --override-existing-serviceaccounts \
  --attach-policy-arn=arn:aws:iam::766746056086:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

  eksctl create iamserviceaccount \
--cluster=<cluster-name> \
--namespace=kube-system \
--name=aws-load-balancer-controller \
--attach-policy-arn=arn:aws:iam::<AWS_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
--override-existing-serviceaccounts \
--region <region-code> \
--approve

  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=drose-highlander-blue \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller 

  #external dns
  aws iam create-policy --policy-name "DRoseAllowExternalDNSUpdates" --policy-document file://externaldns-iam-policy.yaml 

# example: arn:aws:iam::XXXXXXXXXXXX:policy/AllowExternalDNSUpdates
export POLICY_ARN=$(aws iam list-policies \
 --query 'Policies[?PolicyName==`DRoseAllowExternalDNSUpdates`].Arn' --output text)