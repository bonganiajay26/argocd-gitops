#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 01-minikube-setup.sh
# Starts Minikube with production-like resource allocations.
# Enables addons required by ingress, metrics, and storage.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="gitops-platform"
K8S_VERSION="v1.29.0"
CPUS=4
MEMORY="8192"       # 8 GB
DISK="40g"
DRIVER="docker"     # use "hyperkit" on macOS, "hyperv" on Windows

echo "==> Deleting any existing cluster named '${CLUSTER_NAME}'..."
minikube delete --profile "${CLUSTER_NAME}" 2>/dev/null || true

echo "==> Starting Minikube cluster..."
minikube start \
  --profile="${CLUSTER_NAME}" \
  --kubernetes-version="${K8S_VERSION}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --disk-size="${DISK}" \
  --driver="${DRIVER}" \
  --container-runtime=containerd \
  --extra-config=apiserver.enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota \
  --extra-config=controller-manager.bind-address=0.0.0.0 \
  --extra-config=scheduler.bind-address=0.0.0.0

echo "==> Setting default profile..."
minikube profile "${CLUSTER_NAME}"

echo "==> Enabling required addons..."
minikube addons enable metrics-server   --profile="${CLUSTER_NAME}"
minikube addons enable storage-provisioner --profile="${CLUSTER_NAME}"
minikube addons enable default-storageclass --profile="${CLUSTER_NAME}"
# NOTE: We install NGINX ingress manually via Helm for full control
# minikube addons enable ingress  ← skip this

echo "==> Creating namespaces..."
kubectl create namespace argocd       --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev          --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace staging      --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod         --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring   --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

echo "==> Labelling namespaces for network policies..."
kubectl label namespace dev          environment=dev    --overwrite
kubectl label namespace staging      environment=staging --overwrite
kubectl label namespace prod         environment=prod   --overwrite
kubectl label namespace monitoring   environment=ops    --overwrite

echo "==> Cluster info:"
kubectl cluster-info
kubectl get nodes -o wide

echo ""
echo "✓ Minikube cluster '${CLUSTER_NAME}' is ready."
echo "  Minikube IP: $(minikube ip --profile=${CLUSTER_NAME})"
echo ""
echo "  Add to /etc/hosts (run as sudo):"
MINIKUBE_IP=$(minikube ip --profile="${CLUSTER_NAME}")
echo "  ${MINIKUBE_IP}  argocd.local grafana.local app.dev.local app.staging.local app.prod.local"
