#!/usr/bin/bash

# Install required packages
sudo apt-get update
sudo apt-get -y install curl git

# Install docker in host system
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh

# Post-installation steps for Linux
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker

# Install k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install ArgoCD CLI
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

# Create k3d cluster
k3d cluster create p3 --api-port 6550 -p "8081:80@loadbalancer" --servers 1 --agents 2

# Install ArgoCD
kubectl create namespace argocd
kubectl config set-context --current --namespace=argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch deployment argocd-server -n argocd -p '{"spec": {"template": {"spec": {"containers": [{"name": "argocd-server", "args": ["/usr/local/bin/argocd-server", "--insecure", "--rootpath", "/argo-cd"]}]}}}}'
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
kubectl apply -f ./argocd-ingress-route.yaml

argocd login --core
argocd cluster add k3d-p3

# Install inspektor application
kubectl create namespace dev
argocd app create inspektor --repo https://github.com/AdrianWR/inspektor.git --path deployments --dest-server https://kubernetes.default.svc --dest-namespace dev

