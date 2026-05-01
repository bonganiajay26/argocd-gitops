#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 03-install-monitoring.sh
# Installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager).
# Uses values from monitoring/kube-prometheus-values.yaml.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CHART_VERSION="58.3.1"   # kube-prometheus-stack
MONITORING_NS="monitoring"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

echo "==> Adding prometheus-community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> Installing kube-prometheus-stack ${CHART_VERSION}..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NS}" \
  --version "${CHART_VERSION}" \
  --create-namespace \
  --values "${REPO_ROOT}/monitoring/kube-prometheus-values.yaml" \
  --wait \
  --timeout=10m

echo "==> Waiting for Prometheus and Grafana..."
kubectl rollout status statefulset/prometheus-kube-prometheus-stack-prometheus -n "${MONITORING_NS}" --timeout=180s
kubectl rollout status deployment/kube-prometheus-stack-grafana                -n "${MONITORING_NS}" --timeout=180s

echo ""
echo "==> Monitoring pods:"
kubectl get pods -n "${MONITORING_NS}"

echo ""
echo "==> Grafana credentials:"
echo "    URL: http://grafana.local (after ingress setup)"
echo "    Username: admin"
echo "    Password: $(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"

echo ""
echo "==> Applying custom alerting rules..."
kubectl apply -f "${REPO_ROOT}/monitoring/alerting-rules/" -n "${MONITORING_NS}"
