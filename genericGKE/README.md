# This are example of a Neo4j Standalone and Cluster
- 1 standalone Neo4j
- 3 core primary Neo4j members

- GKE Load balancers do not have annotations to terminate at the LB
  - https://cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer-parameters
- Examples of a basic start and stop are in restart folder along with the helm commands needed.
- Example of Neo4j Reverse Proxy
- Rudimentary docker files are present - these are used in the cluster creation
  - axb-debug is apoc, extended and bloom
  - axbg-debug is apoc, extened, bloom and GDS
- Docker build command (this is AMD64, you can do ARM64 )
docker buildx build --platform linux/amd64 -t us-central1-docker.pkg.dev/neo4j-se-team-201905/rosenblum-test/neo4j-axeb2110g265:enterprise-amd-5.19.0 --push axb-debug/.
