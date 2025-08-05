# Neo4j Hybrid GDS Cluster

This are an example of a Neo4j Hybrid GDS Cluster
- 3 core primary Neo4j members
- 1 secondary Neo4j GDS members

Load balancers terminate TLS and do TCP to Neo4j
- 1 load balancer for the Core primary members.
- 1 load balancer for each GDS members - this is needed as GDS calls are done on a non-routing bolt connection

Basic start and stop of the nodepools are in [scripts](./scripts/) folder along with the helm commands needed.

Once the server is up and running, you'll need to alter the topology of the neo4j DB. Doing so will replicate the DB to the secondary/GDS server. Log into the primary LB and issue the following cypher.

```cypher
ALTER DATABASE neo4j SET TOPOLOGY 3 PRIMARY 1 SECONDARY
```

**NOTE**: If you are using certs, leave load balancers running so IP addresses don't change and wreck the certs (I don't have DSN setup)

## Shell into a pod
```bash
kubectl exec neo4j-core-1-0 -i -t -- bash
```

# Taking backups ([docs](https://neo4j.com/docs/operations-manual/current/kubernetes/operations/backup-restore/))
First step is to create an Azure credentials file which contains AZURE_STORAGE_ACCOUNT_NAME and AZURE_STORAGE_ACCOUNT_KEY environment variables with their values.

```bash
kubectl create secret generic azurecred --from-file=credentials=azure-credentials.sh
```

Two options exist to take backups.

```bash
# Create backup schedule
helm install jhair-backup . \
     --set neo4jaddr=neo4j-aks-hybrid-cluster.default.svc.cluster.local:6362 \
     --set bucket=jhairstorage \
     --set database="neo4j\,system" \
     --set cloudProvider=azure \
     --set secretName=azurecred \
     --set jobSchedule="30 * * * *"
```

Or specify the schedule within a [yaml](./backup-values.yaml) file

```bash
helm install jhair-backup neo4j/neo4j-admin -f backup-values.yaml
```

Once the schedule is created, you can view the cronjob within k8s
```bash
kubectl get cronjob --all-namespaces
```