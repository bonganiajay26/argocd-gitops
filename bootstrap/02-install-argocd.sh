#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 02-install-argocd.sh
# Installs ArgoCD via Helm with production-grade configuration.
# Enables insecure mode for local ingress (TLS terminated at ingress layer).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ARGOCD_VERSION="6.7.3"   # Helm chart version → ArgoCD 2.10.x
ARGOCD_NS="argocd"
ADMIN_PASSWORD="GitOps@2024!"   # change in production; use sealed-secrets

echo "==> Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Installing ArgoCD ${ARGOCD_VERSION}..."
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NS}" \
  --version "${ARGOCD_VERSION}" \
  --create-namespace \
  --set server.insecure=true \
  --set server.extraArgs[0]="--insecure" \
  --set configs.params."server\.insecure"=true \
  --set "configs.secret.argocdServerAdminPassword=$(htpasswd -nbBC 10 '' ${ADMIN_PASSWORD} | tr -d ':\n' | sed 's/$2y/$2a/')" \
  --set server.service.type=ClusterIP \
  --set repoServer.replicas=1 \
  --set applicationSet.replicas=1 \
  --set controller.replicas=1 \
  --set redis-ha.enabled=false \
  --set redis.enabled=true \
  --wait \
  --timeout=5m

echo "==> Waiting for ArgoCD pods..."
kubectl rollout status deployment/argocd-server        -n "${ARGOCD_NS}" --timeout=120s
kubectl rollout status deployment/argocd-repo-server   -n "${ARGOCD_NS}" --timeout=120s
kubectl rollout status deployment/argocd-applicationset-controller -n "${ARGOCD_NS}" --timeout=120s

echo "==> ArgoCD pods:"
kubectl get pods -n "${ARGOCD_NS}"

# ── CLI login ────────────────────────────────────────────────────────────────
echo ""
echo "==> To log in via CLI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:80 &"
echo "    argocd login localhost:8080 --username admin --password '${ADMIN_PASSWORD}' --insecure"
echo ""
echo "==> Or via Ingress (after step 04): http://argocd.local"
echo "    username: admin"
echo "    password: ${ADMIN_PASSWORD}"
