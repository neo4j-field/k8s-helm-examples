#!/bin/bash

echo "=== Checking Pod Status ==="
kubectl get pods -n neo4j -o wide

echo -e "\n=== Describe Pending Pods ==="
kubectl describe pod -n neo4j | grep -A 30 "^Events:"

echo -e "\n=== Check PVC Status ==="
kubectl get pvc -n neo4j

echo -e "\n=== Describe PVC ==="
kubectl describe pvc -n neo4j

echo -e "\n=== Check StatefulSet ==="
kubectl get statefulset -n neo4j -o yaml | grep -A 20 "tolerations:\|nodeSelector:"

echo -e "\n=== Verify Node Labels ==="
kubectl get nodes --show-labels | grep neo4jpool

echo -e "\n=== Check Node Taints ==="
kubectl describe nodes -l agentpool=neo4jpool | grep -A 3 "Taints:"

echo -e "\n=== Check Events ==="
kubectl get events -n neo4j --sort-by='.lastTimestamp' | tail -30

echo -e "\n=== Check if pods can tolerate taints ==="
kubectl get pods -n neo4j -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.tolerations}{"\n"}{end}'
