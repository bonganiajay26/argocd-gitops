#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 04-install-ingress.sh
# Installs NGINX Ingress Controller and configures /etc/hosts for local access.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INGRESS_VERSION="4.10.0"
INGRESS_NS="ingress-nginx"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

echo "==> Adding ingress-nginx Helm repo..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

echo "==> Installing NGINX Ingress Controller ${INGRESS_VERSION}..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "${INGRESS_NS}" \
  --version "${INGRESS_VERSION}" \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.nodeSelector."kubernetes\.io/os"=linux \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --set controller.hostPort.enabled=false \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=true \
  --set controller.metrics.serviceMonitor.namespace=monitoring \
  --set controller.podAnnotations."prometheus\.io/scrape"="true" \
  --set controller.podAnnotations."prometheus\.io/port"="10254" \
  --wait \
  --timeout=5m

echo "==> Waiting for ingress controller..."
kubectl rollout status deployment/ingress-nginx-controller -n "${INGRESS_NS}" --timeout=120s

echo "==> Applying ingress resources..."
kubectl apply -f "${REPO_ROOT}/ingress/ingress-resources.yaml"

# ── Minikube tunnel for NodePort access ─────────────────────────────────────
MINIKUBE_IP=$(minikube ip --profile=gitops-platform 2>/dev/null || minikube ip)

echo ""
echo "==> Add these entries to /etc/hosts (requires sudo):"
echo ""
echo "    ${MINIKUBE_IP}  argocd.local grafana.local app.dev.local app.staging.local app.prod.local"
echo ""

read -rp "Auto-update /etc/hosts? [y/N] " confirm
if [[ "${confirm}" == "y" || "${confirm}" == "Y" ]]; then
  # Remove old entries
  sudo sed -i.bak '/argocd\.local\|grafana\.local\|app\.dev\.local\|app\.staging\.local\|app\.prod\.local/d' /etc/hosts
  # Add new entries
  echo "${MINIKUBE_IP}  argocd.local grafana.local app.dev.local app.staging.local app.prod.local" | sudo tee -a /etc/hosts
  echo "✓ /etc/hosts updated."
fi

echo ""
echo "==> Ingress controller NodePort:"
kubectl get svc ingress-nginx-controller -n ingress-nginx
