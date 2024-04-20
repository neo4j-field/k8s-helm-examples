# This are an example of a Neo4j Hybrid GDS Cluster

- 3 core primary Neo4j members
- 2 secondary Neo4j GDS members
- Load balancers terminate TLS and do TCP to Neo4j
- 1 load balancer for each GDS members - this is needed as GDS calls are done on a non-routing bolt connection
- 1 load balancer for the Core primary members.
- Examples of a basic start and stop of the nodepools are in restart folder along with the helm commands needed.
- We leave load balancers running so IP addresses don't change and wreck the certs (I don't have DNS setup)
- Rudimentary docker files are present 
  - axb-debug is for core (no gds) 
  - axbg-debug is for secondary GDS - you can remove the extra installs for production
- Docker build command (this is ARM64, you can do AMD64 )
`docker buildx build --platform linux/arm64 -t <subscription>.dkr.ecr.us-east-2.amazonaws.com/drose-repo:neo4j-axeb2110g255-5.14.0-enterprise-arm --push axbg-debug/.`
