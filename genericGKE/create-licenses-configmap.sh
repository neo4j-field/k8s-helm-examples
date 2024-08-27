kubectl delete configmap license-config > /dev/null 2>&1 
kubectl create configmap license-config --from-file=licenses/
kubectl describe configmaps license-config
