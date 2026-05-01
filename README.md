# Production-Grade GitOps Platform on Minikube

> **Stack:** Minikube · ArgoCD · Prometheus · Grafana · NGINX Ingress · Kustomize · Helm  
> **Pattern:** App-of-Apps · Multi-environment (dev / staging / prod) · GitOps single source of truth

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DEVELOPER WORKSTATION                              │
│                                                                             │
│   ┌──────────┐    git push     ┌─────────────────────────────────────────┐ │
│   │ Developer│ ──────────────► │         Git Repository (Mono-repo)      │ │
│   └──────────┘                 │                                         │ │
│                                │  /apps          /argocd      /monitoring│ │
│                                │   ├── sample-app  ├── app-of-apps.yaml  │ │
│                                │   │   ├── base    └── applications/     │ │
│                                │   │   └── overlays    ├── dev/          │ │
│                                │   └── helm-charts     ├── staging/      │ │
│                                │                       └── prod/         │ │
│                                └─────────────┬───────────────────────────┘ │
└──────────────────────────────────────────────│─────────────────────────────┘
                                               │ ArgoCD polls / webhook
                                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MINIKUBE CLUSTER (local)                             │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    argocd namespace                                  │  │
│  │                                                                      │  │
│  │   ┌────────────────┐    ┌─────────────┐    ┌──────────────────────┐ │  │
│  │   │  ArgoCD Server │    │  App-of-Apps│    │  Application Set     │ │  │
│  │   │  (UI + API)    │◄───│  (root app) │    │  (dev/staging/prod)  │ │  │
│  │   └────────────────┘    └─────────────┘    └──────────────────────┘ │  │
│  │   ┌────────────────┐    ┌─────────────┐                             │  │
│  │   │  Repo Server   │    │  App        │                             │  │
│  │   │  (git clone)   │    │  Controller │                             │  │
│  │   └────────────────┘    └─────────────┘                             │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────────────────┐   │
│  │  dev namespace │  │staging namespace│  │    prod namespace          │   │
│  │                │  │                │  │                             │   │
│  │ sample-app:dev │  │sample-app:stg  │  │  sample-app:prod            │   │
│  │ replicas: 1    │  │ replicas: 2    │  │  replicas: 3                │   │
│  │ resources: low │  │ resources: med │  │  resources: high + HPA      │   │
│  └────────────────┘  └────────────────┘  └────────────────────────────┘   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                   monitoring namespace                               │  │
│  │                                                                      │  │
│  │  ┌──────────────┐  ┌───────────────┐  ┌────────────────────────┐   │  │
│  │  │  Prometheus  │  │    Grafana    │  │  Alertmanager          │   │  │
│  │  │  (metrics)   │  │  (dashboards) │  │  (alerts → email/slack)│   │  │
│  │  └──────┬───────┘  └───────────────┘  └────────────────────────┘   │  │
│  │         │ scrapes ServiceMonitors                                    │  │
│  └─────────│────────────────────────────────────────────────────────────┘  │
│            │                                                                │
│  ┌─────────▼────────────────────────────────────────────────────────────┐  │
│  │              ingress-nginx namespace                                 │  │
│  │                                                                      │  │
│  │   ┌─────────────────────────────────────────────────────────────┐   │  │
│  │   │  NGINX Ingress Controller                                   │   │  │
│  │   │  argocd.local → argocd-server                               │   │  │
│  │   │  grafana.local → grafana svc                                │   │  │
│  │   │  app.dev.local → sample-app (dev)                           │   │  │
│  │   │  app.staging.local → sample-app (staging)                   │   │  │
│  │   │  app.prod.local → sample-app (prod)                         │   │  │
│  │   └─────────────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘

DATA FLOW:
  1. Developer commits code change
  2. Git repo updated (single source of truth)
  3. ArgoCD detects diff (poll interval: 3 min or webhook)
  4. ArgoCD applies Kustomize/Helm manifests to target namespace
  5. Kubernetes reconciles desired → actual state
  6. Prometheus scrapes metrics from all pods via ServiceMonitors
  7. Grafana visualizes; Alertmanager fires on threshold breaches
```

---

## Quick Start (TL;DR)

```bash
# 1. Start Minikube
./bootstrap/01-minikube-setup.sh

# 2. Install core components
./bootstrap/02-install-argocd.sh
./bootstrap/03-install-monitoring.sh
./bootstrap/04-install-ingress.sh

# 5. Bootstrap GitOps with App-of-Apps
./bootstrap/05-bootstrap-gitops.sh

# 6. Access UIs (add to /etc/hosts first — script does this)
open http://argocd.local
open http://grafana.local
```

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Minikube Configuration](#minikube-configuration)
3. [Repository Structure](#repository-structure)
4. [ArgoCD Setup](#argocd-setup)
5. [Application Deployment](#application-deployment)
6. [Monitoring & Observability](#monitoring--observability)
7. [Ingress & Networking](#ingress--networking)
8. [Security & RBAC](#security--rbac)
9. [Scaling & Reliability](#scaling--reliability)
10. [Troubleshooting](#troubleshooting)
11. [Advanced Enhancements](#advanced-enhancements)

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Minikube | ≥ 1.32 | `brew install minikube` |
| kubectl | ≥ 1.28 | `brew install kubectl` |
| Helm | ≥ 3.13 | `brew install helm` |
| ArgoCD CLI | ≥ 2.9 | `brew install argocd` |
| Git | any | pre-installed |

---

## Repository Structure

```
ARGOCD-WORKFLOW/                          ← Git root (single source of truth)
│
├── bootstrap/                            ← One-time cluster setup scripts
│   ├── 01-minikube-setup.sh
│   ├── 02-install-argocd.sh
│   ├── 03-install-monitoring.sh
│   ├── 04-install-ingress.sh
│   └── 05-bootstrap-gitops.sh
│
├── argocd/                               ← ArgoCD app definitions
│   ├── app-of-apps.yaml                  ← Root application
│   ├── projects/                         ← AppProject resources
│   │   ├── dev-project.yaml
│   │   ├── staging-project.yaml
│   │   └── prod-project.yaml
│   └── applications/                     ← Child app definitions
│       ├── dev/
│       │   └── sample-app-dev.yaml
│       ├── staging/
│       │   └── sample-app-staging.yaml
│       └── prod/
│           └── sample-app-prod.yaml
│
├── apps/                                 ← Application manifests
│   └── sample-app/
│       ├── base/                         ← Kustomize base
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── serviceaccount.yaml
│       │   └── kustomization.yaml
│       └── overlays/                     ← Per-environment patches
│           ├── dev/
│           │   ├── kustomization.yaml
│           │   └── patch-deployment.yaml
│           ├── staging/
│           │   ├── kustomization.yaml
│           │   └── patch-deployment.yaml
│           └── prod/
│               ├── kustomization.yaml
│               ├── patch-deployment.yaml
│               └── hpa.yaml
│
├── helm-charts/                          ← Custom Helm charts
│   └── sample-app/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-dev.yaml
│       ├── values-staging.yaml
│       ├── values-prod.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── hpa.yaml
│           └── servicemonitor.yaml
│
├── monitoring/                           ← Prometheus/Grafana config
│   ├── kube-prometheus-values.yaml
│   ├── alerting-rules/
│   │   └── app-alerts.yaml
│   └── dashboards/
│       └── sample-app-dashboard.json
│
├── ingress/                              ← Ingress resources
│   └── ingress-resources.yaml
│
├── security/                             ← RBAC + secrets
│   ├── rbac/
│   │   ├── dev-rbac.yaml
│   │   ├── staging-rbac.yaml
│   │   └── prod-rbac.yaml
│   └── sealed-secrets/
│       └── README.md
│
└── ci/                                   ← GitHub Actions workflows
    └── workflows/
        ├── ci.yaml
        └── promote.yaml
```
