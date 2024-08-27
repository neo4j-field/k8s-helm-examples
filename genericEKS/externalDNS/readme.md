# Example getting externaldns running on EKS.

## Assumptions - you already have an EKS cluster running with OIDC


## Sources
Sources are AWS docs and the github for kubernetes-sig/external-dns - read these links first - really!  There are several methods to get ExternalDNS working - the method that used the principal of least privileges is IAM Roles for Service Account.  I felt that would be most appropriate for my prospects and clients, and myself.  This work was done on a Mac - so Linux should work, but Windows users will need to use WSL or a cloud shell.

[ExternalDNS on Github](https://github.com/kubernetes-sigs/external-dns)

[ExternalDNS Tutorial for AWS](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/aws.md)

## Prerequisites

### AWS Load Balancer Controller 
I recommend using the aws load balancer controller below.  It has better control of the NLB thru annotations, and my other examples will assume you are using it.  If you don't have this running - you will be using the EKS in-tree load balancer controller, and some annotations will not work, because the in-tree doesn't know about them.  

#### GitHub [AWS Load Balancer Controller](https://github.com/kubernetes-sigs/aws-load-balancer-controller)
#### Annotations Docs [AWS LBC Annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/)
### Route53
You will need a domain in aws Route53 - I used a private domain called drose-private.com

[AWS Create Private Domain](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-creating.html)


### Setup exports for your cluster for the code below
Create the namespace as needed e.g. `kubectl create namespace neo4j`
```
export EKS_CLUSTER_NAME=drose-highlander-green
export DNS_NAME=drose-private.com
export EKS_CLUSTER_REGION=us-east-2
export DNS_NAMESPACE=neo4j
```
## AWS Policies and IAM Services Accounts
### IAM Policy 

From the tutorial above I saved the policy as externalDNSPolicy.yaml you can of course be more restrictive - refer to the tutorial

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResource"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
```
#### Create the policy
```
aws iam create-policy --policy-name "AllowExternalDNSUpdates" --policy-document file://externaldns/externalDNSPolicy.yaml
```
#### Pick a name for your IAM Service Account and export it
```
# The tutorial uses external-dns as the name of everything, I don't - I find it confusing.
export IAM_SVC_ACCT=ext-dns-iam-svc-acct
```
#### The Policy ARN is needed by the external dns servics
```
export POLICY_ARN=$(aws iam list-policies \
 --query 'Policies[?PolicyName==`AllowExternalDNSUpdates`].Arn' --output text)
 ```
### Create the IAM Service Account
The IAM Service Account name exported to $IAM_SVC_ACCT (i.e. ext-dns-iam-svc-acct) and the namespace used (i.e. neo4j) in the creation of the IAM Service Account must match the ClusterRoleBinding settings in the subjects: --> name: and namespace: entry in the yaml that create the external dns deployment (externaldns-with-rbac.yaml)
 
```
  eksctl create iamserviceaccount \
  --cluster $EKS_CLUSTER_NAME \
  --name $IAM_SVC_ACCT \
  --namespace $DNS_NAMESPACE \
  --attach-policy-arn $POLICY_ARN \
  --approve
```
# Deploy ExternalDNS
There are several methods to deploy ExternalDNS.  Since we are using an RBAC enabled Cluster we will ignore Manifest (for clusters without RBAC enabled).  We got the Manifest (for clusters with RBAC enabled) working first, and will come back to helm at a future time.
## Deploy Manifest (for clusters with RBAC enabled)
### Download and save the manifest in externaldns/externaldns-with-rbac.yaml
[externaldns-with-rbac.yaml](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/aws.md#manifest-for-clusters-with-rbac-enabled)
### Make Changes for your environment
#### Change ClusterRoleBinding
note changes to name and namespace below
 ```
 apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
  labels:
    app.kubernetes.io/name: external-dns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
  - kind: ServiceAccount
    name: ext-dns-iam-svc-acct
    namespace: neo4j # change to desired namespace: externaldns, kube-addons
```
#### Change Deployment to use svc account, dns, etc
Note change serviceAccountName, txt-owner-id to ext-dns-iam-svc-acct or whatever you used.

Note change domain-filter to your domain,  drose-private.com in my example and change the aws-zone-type matches your Route53 setting (private or public).  The example in the this repo may vary slightly from the ExternalDNS AWS tutorial to reflect my private hosted DNS use case.
A comment about  --policy=sync  if you do this with a blue/green (multiple EKS clusters) setting in the same dns name, then each EKS cluster only knows about it's own DNS records and there is constant creation and deletion.  For this reason I have used upsert-only.

```apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  labels:
    app.kubernetes.io/name: external-dns
spec:
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: external-dns
  template:
    metadata:
      labels:
        app.kubernetes.io/name: external-dns
    spec:
      serviceAccountName: ext-dns-iam-svc-acct
      containers:
        - name: external-dns
          image: registry.k8s.io/external-dns/external-dns:v0.14.1
          args:
            - --source=service
            - --source=ingress
            - --domain-filter=drose-private.com # will make ExternalDNS see only the hosted zones matching provided domain, omit to process all available hosted zones
            - --provider=aws
            - --policy=upsert-only # would prevent ExternalDNS from deleting any records, omit to enable full synchronization
            - --aws-zone-type=private # only look at public hosted zones (valid values are public, private or no value for both)
            - --registry=txt
            - --txt-owner-id=ext-dns-iam-svc-acct
          env:
            - name: AWS_DEFAULT_REGION
              value: us-east-2 # change to region where EKS is installed
```
### Run kubectl create to do the actual deployment
```
kubectl create --filename externalDNS/externaldns-with-rbac.yaml    
```
## ToDo - Working Helm example 
Might (will) be easier to pass the env variable than edit the file if the helm behavior is the same
## Example of Neo4j Load Balancer for internal (not client) use, e.g Discovery
```
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    #below is my us-east-2a private subnet
    service.beta.kubernetes.io/aws-load-balancer-subnets: "subnet-0a314fd1814f79a41"
    external-dns.alpha.kubernetes.io/hostname: mlb1.drose-private.com
  labels:
    helm.neo4j.com/instance: multi1
  name: multi1a-internal-2a-1
  namespace: "neo4j"
spec:
  #externalTrafficPolicy: Local
  publishNotReadyAddresses: true
  ports:
  - name: ssr
    port: 7688
    protocol: TCP
    targetPort: 7688
  - name: raft 
    port: 5000
    protocol: TCP
    targetPort: 5000  
  - name: raft-disc 
    port: 6000
    protocol: TCP
    targetPort: 6000
  - name: raft-tx
    port: 7000
    protocol: TCP
    targetPort: 7000      
  selector:
    # We need one (1) LB for each pod to use for discovery/internal use
    helm.neo4j.com/instance: multi1
    # The examples in the Neo4j Docs use app for the selector - one per cluster
    #app: playsmall
  sessionAffinity: None
  type: LoadBalancer

```
## Example of looking at the Route53 Entries from command line - I used console.
```
export ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json \
  --dns-name "drose-private.com." --query "HostedZones[0].Id" --out text)
 
aws route53 list-resource-record-sets --output json --hosted-zone-id $ZONE_ID 

```
## Other Topics
### Look in the awsLoadBalancer directory for examples of that (ToDO)
### Look in Neo4jListDiscovery for examples of how to use Neo4j in EKS with LIST or DSN instead of K8S (ToDo)