eksctl create iamserviceaccount \
  --cluster=drose-tc3 \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::766746056086:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve