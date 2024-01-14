#!/usr/bin/bash

LOAD_BALANCER_PORT=${1:-8081}

# Install required packages

# Add Docker's official GPG key
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

# Install docker in host system
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin


# Post-installation steps for Linux
sudo groupadd -f docker
sudo usermod -aG docker $USER

#Install k3d
sg docker -c "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"

# Install kubectl
sg docker -c '
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
'


# "Install ArgoCD CLI"
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sg docker -c 'sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd'
rm argocd-linux-amd64

# "Create k3d cluster"
echo "Create k3d cluster"
sg docker -c 'k3d cluster create p3 --api-port 6550 -p "${LOAD_BALANCER_PORT}:80@loadbalancer" --servers 1 --agents 2'
echo "Merge Cluster"
sg docker -c 'k3d kubeconfig merge p3 --kubeconfig-switch-context'

# Install ArgoCD
echo "Install ArgoCD"
sg docker -c "kubectl create namespace argocd"
echo "Set ArgoCD Context"
sg docker -c "kubectl config set-context --current --namespace=argocd"
echo "Apply ArgoCD"
sg docker -c "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

echo "Patch Deployment"
sg docker -c "
kubectl patch deployment argocd-server -n argocd -p '{\"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"argocd-server\", \"args\": [\"/usr/local/bin/argocd-server\", \"--insecure\", \"--rootpath\", \"/argo-cd\"]}]}}}}'
"

echo "Waiting for Kubectl"
sg docker -c 'kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/name=argocd-server" -n argocd --timeout=60s'

echo "Applying Ingress Route"
sg docker -c "
cat <<EOF | kubectl apply -f -
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: PathPrefix('/argo-cd')
      priority: 10
      services:
        - name: argocd-server
          port: 80
    - kind: Rule
      match: Host('/argo-cd') && Headers('Content-Type', 'application/grpc')
      priority: 11
      services:
        - name: argocd-server
          port: 80
          scheme: h2c
EOF
"

sg docker -c "argocd login --core"
echo "Add Cluster"
# AQUI ELE FALHA: FATA[0000] Context k3d-p3 does not exist in kubeconfig  
sg docker -c "argocd cluster add k3d-p3"


# "Install inspektor application"
echo "Install inspektor application"
sg docker -c "argocd app create inspektor --repo https://github.com/AdrianWR/inspektor.git --path deployments --dest-server https://kubernetes.default.svc --dest-namespace dev"

# Print ArgoCD credentials
echo -e "ArgoCD username:\nadmin\n"
echo "ArgoCD password:"
sg docker -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"