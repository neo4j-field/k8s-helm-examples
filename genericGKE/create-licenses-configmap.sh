kubectl delete configmap license-config > /dev/null
kubectl create configmap license-config --from-file=licenses/
kubectl describe configmaps license-config
