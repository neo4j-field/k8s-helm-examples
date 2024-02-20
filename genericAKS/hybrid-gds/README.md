# Neo4j Hybrid GDS Cluster

This are an example of a Neo4j Hybrid GDS Cluster
- 3 core primary Neo4j members
- 1 secondary Neo4j GDS members

Load balancers terminate TLS and do TCP to Neo4j
- 1 load balancer for each GDS members - this is needed as GDS calls are done on a non-routing bolt connection
- 1 load balancer for the Core primary members.

basic start and stop of the nodepools are in restart folder along with the helm commands needed.
I leave load balancers running so IP addresses don't change and wreck the certs (I don't have DSN setup)
