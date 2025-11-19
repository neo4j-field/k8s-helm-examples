DBNAME=goingmeta
BACKUP_FILE=azb://jhairstorage/backups/goingmeta-2025-08-08T19-05-24.backup

AKS_RESOURCE_GROUP=jhair-helm-rg
AKS_REGION=eastus

AKS_CLUSTER_NAME=neo4j-aks-hybrid-cluster
AKS_NAMESPACE=neo4j-hybrid
AKS_NODEPOOL_NAME=neo4j

# Drop the database
kubectl exec neo4j-core-1-0 -i -t -- bash
DBNAME=goingmeta
BACKUP_FILE=azb://jhairstorage/backups/goingmeta-2025-08-08T19-05-24.backup

cypher-shell -u neo4j -p 'my-password' -d system <<EOF
DROP DATABASE goingmeta IF EXISTS;
EOF

## Need to use an image with Neo4j and AZ CLI installed
az login

neo4j-admin database restore --from-path=azb://jhairstorage/backups/goingmeta-2025-08-08T19-05-24.backup --expand-commands $DBNAME