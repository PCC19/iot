kubectl delete all --all
kubectl delete namespace dev
kubectl delete namespace argocd
k3d cluster rm p3
rm -rf ~/.kube
