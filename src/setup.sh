#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Criar cluster k3d
k3d cluster create mycluster --servers 1 --agents 2 -p "8080:80@loadbalancer"

# 2. Build e importar imagem
docker build -t php-apache-k8s:v1 .
k3d image import php-apache-k8s:v1 -c mycluster

# 3. Deploy da aplicação
kubectl apply -f k8s/app-deployment.yaml
kubectl apply -f k8s/app-service.yaml

# 4. Instalar Metrics Server (manifest oficial) + flags para ambiente local
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server \
  --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"}
  ]'

# 5. Criar HPA
kubectl apply -f k8s/hpa.yaml

echo "✅ Cluster rodando em http://localhost:8080"
