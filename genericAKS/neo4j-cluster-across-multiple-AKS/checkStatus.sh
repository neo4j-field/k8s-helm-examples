echo "Retrieving Neo4j log files"

for region in eastus westus2 centralus; do
  echo "************** Reviewing $region deployment..."
  kubectl config use-context neo4j-aks-${region}

  echo "Retrieving log files ..."
  kubectl cp neo4j/neo4j-${region}-0:/logs/neo4j.log ./logs/${region}-neo4j.log &>/dev/null
  kubectl cp neo4j/neo4j-${region}-0:/logs/debug.log ./logs/${region}-debug.log &>/dev/null

  # kubectl get statefulset neo4j-${region} -n neo4j -o yaml | grep -A 20 "ports:"
  kubectl get pods -n neo4j -o wide
  kubectl get svc -n neo4j

  # echo "Checking nodeport endpoints..."
  # kubectl get endpoints neo4j-${region}-raft-nodeport -n neo4j

  echo ""
  # sleep 15
done