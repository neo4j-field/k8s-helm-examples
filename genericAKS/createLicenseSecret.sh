kubectl delete secret  gds-bloom-license > /dev/null 2>&1 
kubectl create secret  generic --from-file=licenses/ gds-bloom-license
kubectl describe secret  gds-bloom-license
