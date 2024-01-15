#!/usr/bin/bash

LOAD_BALANCER_PORT=8081
CLUSTERNAME="p3"
RED="\e[1;96m"
ENDCOLOR="\e[0m"


# Install required packages

# Add Docker's official GPG key
echo -e "${RED}Add Docker's official GPG key${ENDCOLOR}"
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources
echo -e "${RED}Add the repository to Apt sources${ENDCOLOR}"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

# Install docker in host system
echo -e "${RED}Install Docker${ENDCOLOR}"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin


# Post-installation steps for Linux
echo -e "${RED}Setting Groups${ENDCOLOR}"
sudo groupadd -f docker
sudo usermod -aG docker $USER

#Install k3d
sg docker -c "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"

# Install kubectl
echo -e "${RED}Install Kubectl${ENDCOLOR}"
sg docker -c '
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
'

# "Create k3d cluster"
echo -e "${RED}Create k3d cluster${ENDCOLOR}"
sg docker -c "k3d cluster create ${CLUSTERNAME} --api-port 6550 -p ${LOAD_BALANCER_PORT}:80@loadbalancer --servers 1 --agents 2 --kubeconfig-update-default --kubeconfig-switch-context"


# "Install ArgoCD CLI"
echo -e "${RED}Install ArgoCD CLI${ENDCOLOR}"
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sg docker -c 'sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd'
rm argocd-linux-amd64

echo -e "${RED}Apply ArgoCD${ENDCOLOR}"
sg docker -c "kubectl create namespace argocd"
sg docker -c "kubectl config set-context --current --namespace argocd"
sg docker -c "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# Patch Deployment
echo -e "${RED}Patch Deployment${ENDCOLOR}"
sg docker -c "
kubectl patch deployment argocd-server -n argocd -p '{\"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"argocd-server\", \"args\": [\"/usr/local/bin/argocd-server\", \"--insecure\", \"--rootpath\", \"/argo-cd\"]}]}}}}'
"

#Wait for Kubectl
echo -e "${RED}Waiting for Kubectl${ENDCOLOR}"
sg docker -c 'kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/name=argocd-server" -n argocd --timeout=60s'


#Apply Ingress Route
echo -e "${RED}Applying Ingress Route${ENDCOLOR}"

sg docker -c "
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
"

sg docker -c "argocd login --core"


echo -e "${RED}Add Cluster${ENDCOLOR}"
sg docker -c "
argocd cluster add k3d-${CLUSTERNAME} -y
"

# "Install inspektor application"
echo -e "${RED}Install inspektor application${ENDCOLOR}"

sg docker -c "
kubectl create namespace dev
argocd app create inspektor --repo https://github.com/AdrianWR/inspektor-aroque.git --path deployments --dest-server https://kubernetes.default.svc --sync-policy auto --dest-namespace dev
"

# Print ArgoCD credentials
echo -e "ArgoCD username:\nadmin\n"
echo -e "${RED}ArgoCD password:"
sg docker -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"