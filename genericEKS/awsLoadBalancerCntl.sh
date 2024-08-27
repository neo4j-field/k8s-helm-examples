eksctl create iamserviceaccount \
  --cluster=drose-tc3 \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::766746056086:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve



  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=drose-tc3 \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-lb-tc3-controller