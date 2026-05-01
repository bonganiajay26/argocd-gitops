#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 05-bootstrap-gitops.sh
# Seeds ArgoCD with the App-of-Apps root application.
# After this runs, ALL other apps are managed by ArgoCD itself.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ARGOCD_NS="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# ── Update this to your actual Git repo URL ──────────────────────────────────
REPO_URL="${GITOPS_REPO_URL:-https://github.com/bonganiajay26/argocd-gitops.git}"
REPO_BRANCH="${GITOPS_BRANCH:-main}"

echo "==> Logging into ArgoCD..."
kubectl port-forward svc/argocd-server -n argocd 8080:80 &
PF_PID=$!
sleep 3

argocd login localhost:8080 \
  --username admin \
  --password "GitOps@2024!" \
  --insecure

echo "==> Registering Git repository..."
argocd repo add "${REPO_URL}" \
  --name gitops-repo \
  --username git \
  --insecure-skip-server-verification || true

echo "==> Creating AppProjects..."
kubectl apply -f "${REPO_ROOT}/argocd/projects/" -n "${ARGOCD_NS}"

echo "==> Bootstrapping App-of-Apps root application..."
# Substitute actual repo URL into the app-of-apps manifest before applying
sed "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g; s|BRANCH_PLACEHOLDER|${REPO_BRANCH}|g" \
  "${REPO_ROOT}/argocd/app-of-apps.yaml" | kubectl apply -f -

echo "==> Waiting for App-of-Apps to sync..."
argocd app wait root-app-of-apps \
  --sync \
  --timeout 120 || true

kill "${PF_PID}" 2>/dev/null || true

echo ""
echo "==> ArgoCD Applications:"
argocd app list 2>/dev/null || kubectl get applications -n "${ARGOCD_NS}"

echo ""
echo "✓ GitOps bootstrap complete."
echo "  Visit http://argocd.local to manage applications."
