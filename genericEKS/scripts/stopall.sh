helm uninstall playsmall-1 playsmall-2 playsmall-3 playsmall-gds-1 playsmall-gds-2
#helm uninstall neo4j-hybrid-gds3 neo4j-hybrid-gds4  
echo sleeping 30 seconds
sleep 30
echo delete cleanup pods for core members
kubectl get pods -o=name | awk '/playsmall[0-9]-cleanup/{print $1}'| xargs kubectl delete -n efs 
#shouldn't be any gds cleanup
echo delete cleanup pods for gds members
kubectl get pods -o=name | awk '/playsmall-gds[0-9]-cleanup/{print $1}'| xargs kubectl delete -n efs 
sleep 30
eksctl delete nodegroup --config-file=eks_create_cluster2.yaml --include=playsmall --approve
