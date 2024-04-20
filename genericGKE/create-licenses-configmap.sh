kubectl delete configmap license-config
kubectl create configmap license-config --from-file=licenses/
kubectl describe configmaps license-config
