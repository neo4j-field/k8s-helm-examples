# Prerequisites
Before you can deploy a Neo4j standalone instance on Kubernetes, you need to:
- https://neo4j.com/docs/operations-manual/current/kubernetes/quickstart-standalone/prerequisites/
- https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin

# Single, standalone Neo4j instance
  - Basic start and stop scripts are in [scripts](./scripts) folder along with the helm commands needed.
    - start: ```helm upgrade -i standalone  neo4j/neo4j -f standalone.yaml```
    - stop: ```helm uninstall standalone```
  - standalone.yaml uses the default Neo4j image
  - standalone-custom-image.yaml uses a custom image vs the default Neo4j image.
    - The custom docker image shows a read-only root configuration (custom Docker build). 

# 3 Primary (aka core) Neo4j members
TODO
- Example of Neo4j Reverse Proxy

# Building a custom Docker image
- Rudimentary docker files are present - these are used to build a custom Neo4j image
  - axb-debug is apoc, apoc extended and bloom
  - axbg-debug is apoc, apoc extended, bloom and GDS
- Example Docker build command (this is AMD64, you can do ARM64)

  ```docker buildx build --platform linux/amd64 -t us-central1-docker.pkg.dev/neo4j-se-team-201905/rosenblum-test/neo4j-axeb2110g265:enterprise-amd-5.19.0 --push axb-debug/.```


# GKE Load Balancers consideration
GKE Load Balancers do not have annotations to terminate at the LB
https://cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer-parameters
