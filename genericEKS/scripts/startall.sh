eksctl create  nodegroup --config-file=eks_create_cluster2.yaml --include=playsmall
echo sleeping
sleep 10
helm upgrade -i playsmall-1  neo4j/neo4j -f hybrid-core-small.yaml 
sleep 10
helm upgrade -i playsmall-2  neo4j/neo4j -f hybrid-core-small.yaml
sleep 10
helm upgrade -i playsmall-3  neo4j/neo4j -f hybrid-core-small.yaml
sleep 10
helm upgrade -i playsmall-gds-1  neo4j/neo4j -f hybrid-gds-small.yaml 
sleep 10
helm upgrade -i playsmall-gds-2  neo4j/neo4j -f hybrid-gds-small.yaml 
#sleep 1
#helm upgrade -i neo4j-hybrid-gds3  neo4j/neo4j -f hybrid-gds-small.yaml 
#sleep 1
#helm upgrade -i neo4j-hybrid-gds4  neo4j/neo4j -f hybrid-gds.yaml 


helm upgrade -i multi1  neo4j/neo4j -f multi-small1.yaml 
helm upgrade -i multi2  neo4j/neo4j -f multi-small2.yaml 
helm upgrade -i multi3  neo4j/neo4j -f multi-small3.yaml 
