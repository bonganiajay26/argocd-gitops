# How This GitOps Platform Works — Complete Explanation

> A plain-English, deep-dive into every component, how they connect,
> and what happens at each step of the deployment lifecycle.

---

## Table of Contents

1. [What is GitOps?](#1-what-is-gitops)
2. [Platform Overview](#2-platform-overview)
3. [Component Deep-Dive](#3-component-deep-dive)
   - 3.1 [Minikube — The Cluster](#31-minikube--the-cluster)
   - 3.2 [ArgoCD — The GitOps Engine](#32-argocd--the-gitops-engine)
   - 3.3 [Kustomize — Environment Templating](#33-kustomize--environment-templating)
   - 3.4 [Helm — Package Manager Alternative](#34-helm--package-manager-alternative)
   - 3.5 [Prometheus — Metrics Collection](#35-prometheus--metrics-collection)
   - 3.6 [Grafana — Visualization](#36-grafana--visualization)
   - 3.7 [Alertmanager — Alert Routing](#37-alertmanager--alert-routing)
   - 3.8 [NGINX Ingress — External Access](#38-nginx-ingress--external-access)
4. [Repository Structure Explained](#4-repository-structure-explained)
5. [The App-of-Apps Pattern](#5-the-app-of-apps-pattern)
6. [End-to-End Deployment Flow](#6-end-to-end-deployment-flow)
7. [Multi-Environment Strategy](#7-multi-environment-strategy)
8. [Promotion Pipeline](#8-promotion-pipeline)
9. [Monitoring & Observability Flow](#9-monitoring--observability-flow)
10. [Security Model](#10-security-model)
11. [How Everything Connects — Master Data Flow](#11-how-everything-connects--master-data-flow)

---

## 1. What is GitOps?

GitOps is a way of running Kubernetes where **Git is the single source of truth** for
everything — every deployment, every config change, every rollback.

### Traditional Deployment (push model)
```
Developer → runs kubectl apply → Kubernetes
           (manual, error-prone, no audit trail)
```

### GitOps Deployment (pull model)
```
Developer → commits to Git → ArgoCD detects change → ArgoCD applies to Kubernetes
           (automated, auditable, self-healing)
```

### The Four GitOps Principles (OpenGitOps)

| Principle | What it means in this project |
|-----------|-------------------------------|
| **Declarative** | All desired state lives in YAML files (Kustomize overlays, Helm values) |
| **Versioned** | Every change is a Git commit — full history, blame, revert |
| **Pulled automatically** | ArgoCD polls GitHub every 3 min and pulls changes |
| **Continuously reconciled** | If someone manually edits a resource, ArgoCD reverts it |

---

## 2. Platform Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                     THE GITOPS CONTROL LOOP                          │
│                                                                      │
│   Git Repo          ArgoCD               Kubernetes Cluster          │
│  (desired)    ───►  (compare)   ───►     (actual)                    │
│                         │                    │                       │
│                         └────── diff? ───────┘                       │
│                              if yes → apply                          │
│                              if no  → do nothing                     │
└──────────────────────────────────────────────────────────────────────┘
```

This project runs **five major systems** inside one Minikube cluster:

```
┌─────────────────────────────────────────────────────────────────────┐
│  MINIKUBE CLUSTER                                                   │
│                                                                     │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────────────┐  │
│  │ ArgoCD   │   │ dev ns   │   │staging ns│   │  prod ns       │  │
│  │(gitops   │   │sample-app│   │sample-app│   │  sample-app    │  │
│  │ engine)  │   │replica:1 │   │replica:2 │   │  replica:3+HPA │  │
│  └──────────┘   └──────────┘   └──────────┘   └────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────┐   ┌───────────────────────┐  │
│  │ monitoring ns                    │   │ ingress-nginx ns      │  │
│  │ Prometheus + Grafana + Alertmgr  │   │ NGINX Ingress Ctrl    │  │
│  └──────────────────────────────────┘   └───────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Deep-Dive

### 3.1 Minikube — The Cluster

**What it is:** A single-node Kubernetes cluster that runs inside Docker on your laptop.
It simulates a real production cluster with the same API, same controllers, same networking.

**Why we configure it with 4 CPU / 8 GB RAM:**
- ArgoCD needs ~500 MB RAM
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager) needs ~2 GB RAM
- The sample app + ingress controller needs ~500 MB
- Leaving headroom for kube-system components

**Key settings we use:**

```bash
--container-runtime=containerd   # production-grade runtime (same as EKS/GKE)
--extra-config=apiserver.enable-admission-plugins=...ResourceQuota  # enforce limits
```

**Namespaces and their purpose:**

| Namespace | Purpose | Who manages it |
|-----------|---------|---------------|
| `argocd` | ArgoCD control plane | Helm (bootstrap) |
| `dev` | Development workloads | ArgoCD auto-sync |
| `staging` | Staging workloads | ArgoCD auto-sync |
| `prod` | Production workloads | ArgoCD manual-sync |
| `monitoring` | Prometheus, Grafana, Alertmanager | Helm (bootstrap) |
| `ingress-nginx` | NGINX ingress controller | Helm (bootstrap) |

---

### 3.2 ArgoCD — The GitOps Engine

**What it is:** A Kubernetes controller that watches a Git repository and ensures
the cluster matches what's in Git at all times.

**Its internal components:**

```
┌──────────────────────────────────────────────────────────────┐
│                    argocd namespace                          │
│                                                              │
│  ┌─────────────────┐   Clones repo, renders     ┌─────────┐ │
│  │  Repo Server    │◄─ Kustomize/Helm ─────────►│  Redis  │ │
│  │  (git clone +   │   manifests                │ (cache) │ │
│  │   kustomize/    │                            └─────────┘ │
│  │   helm render)  │                                        │
│  └────────┬────────┘                                        │
│           │ rendered manifests                              │
│           ▼                                                  │
│  ┌─────────────────┐   Compares desired vs actual           │
│  │  App Controller │◄─ talks to Kubernetes API ─────────── │
│  │  (reconciler)   │   applies diff if needed              │
│  └────────┬────────┘                                        │
│           │                                                  │
│  ┌────────▼────────┐   REST API + Web UI                   │
│  │  ArgoCD Server  │◄─ you browse http://localhost:8080 ── │
│  │  (UI + API)     │                                        │
│  └─────────────────┘                                        │
│                                                              │
│  ┌─────────────────┐   Creates apps from ApplicationSets   │
│  │  ApplicationSet │                                        │
│  │  Controller     │                                        │
│  └─────────────────┘                                        │
└──────────────────────────────────────────────────────────────┘
```

**The reconciliation loop (runs every 3 minutes):**

```
1. Repo Server clones github.com/bonganiajay26/argocd-gitops.git
2. Runs: kustomize build apps/sample-app/overlays/dev
3. Gets the rendered YAML (Deployment, Service, ServiceAccount, etc.)
4. App Controller fetches current state from Kubernetes API
5. Compares: desired (Git) vs actual (cluster)
6. If different → kubectl apply the diff
7. If same      → reports "Synced", does nothing
```

**Sync policies by environment:**

```yaml
# dev — aggressive auto-sync (push and it deploys immediately)
syncPolicy:
  automated:
    prune: true      # delete resources removed from Git
    selfHeal: true   # revert manual kubectl changes

# prod — human gate (ArgoCD shows OutOfSync but waits)
syncPolicy:
  automated: {}      # empty = disabled, human must click Sync
```

---

### 3.3 Kustomize — Environment Templating

**What it is:** A tool built into kubectl that lets you define a base configuration
once and patch it differently per environment — without duplicating all the YAML.

**How our structure works:**

```
apps/sample-app/
│
├── base/                    ← Shared across ALL environments
│   ├── deployment.yaml      ← The deployment template
│   ├── service.yaml         ← ClusterIP service
│   ├── serviceaccount.yaml  ← Least-privilege SA
│   ├── servicemonitor.yaml  ← Prometheus scrape config
│   └── kustomization.yaml   ← Lists the above files
│
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml    ← "Use base, then apply these patches"
    │   └── patch-deployment.yaml ← replicas: 1, cpu: 25m, debug logs
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patch-deployment.yaml ← replicas: 2, cpu: 50m, info logs
    └── prod/
        ├── kustomization.yaml
        ├── patch-deployment.yaml ← replicas: 3, cpu: 100m, warn logs
        └── hpa.yaml              ← HorizontalPodAutoscaler (prod-only)
```

**What Kustomize does at deploy time:**

```bash
# ArgoCD runs this internally:
kustomize build apps/sample-app/overlays/prod

# Output: one big YAML with base merged + prod patches applied
# Result: Deployment with replicas=3, cpu=100m, podAntiAffinity, etc.
```

**Why not just copy the YAML three times?**
If you need to change the image name, the readiness probe path, or a label,
you change it once in `base/` and all three environments get the update.
Copy-paste means three places to change and three chances to miss one.

---

### 3.4 Helm — Package Manager Alternative

**What it is:** A templating engine + package manager for Kubernetes. Instead of
patching YAML (Kustomize), Helm uses Go templates and values files.

**How we use it in this project:**

1. **Installing third-party software** (ArgoCD, Prometheus, NGINX) — we use
   community Helm charts so we don't have to write thousands of lines of YAML ourselves.

2. **Our own sample-app chart** (`helm-charts/sample-app/`) — an alternative
   to the Kustomize approach, showing how a Helm-based workflow would look.

**Kustomize vs Helm — when to use which:**

| | Kustomize | Helm |
|--|-----------|------|
| **Best for** | Your own apps, simple patching | Third-party charts, complex templating |
| **Templating** | Strategic merge patches | Go templates (`{{ .Values.x }}`) |
| **Package ecosystem** | No (you own the YAML) | Yes (Artifact Hub) |
| **ArgoCD support** | Native | Native |
| **Learning curve** | Low | Medium |

This project uses **Kustomize for app deployment** (overlays) and
**Helm for infrastructure** (ArgoCD, monitoring, ingress).

---

### 3.5 Prometheus — Metrics Collection

**What it is:** A time-series database that scrapes HTTP `/metrics` endpoints
from your pods every 30 seconds and stores the numbers.

**How it discovers what to scrape (ServiceMonitor pattern):**

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  ServiceMonitor CR ──► Prometheus Operator ──► Prometheus   │
│  (your config)         (reads CRs, updates    (scrapes      │
│                         Prometheus config)     the targets) │
│                                                              │
│  Without Operator, you'd edit prometheus.yml by hand.       │
│  With Operator, you just apply a ServiceMonitor YAML.       │
└──────────────────────────────────────────────────────────────┘
```

**Our ServiceMonitor (in `apps/sample-app/base/servicemonitor.yaml`):**

```yaml
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: sample-app   # find pods with this label
  endpoints:
    - port: http
      path: /metrics                        # scrape this path
      interval: 30s                         # every 30 seconds
```

**What Prometheus stores for each scrape:**

```
# Each metric is a time series:
container_cpu_usage_seconds_total{
  namespace="prod",
  pod="sample-app-abc123",
  container="sample-app"
} = 0.045   @ timestamp 1714563600
```

**Key metrics we alert on:**

| Metric | What it measures |
|--------|-----------------|
| `up{job="sample-app"}` | Is the pod responding to scrapes? |
| `container_cpu_usage_seconds_total` | CPU usage per container |
| `container_memory_working_set_bytes` | RAM in use |
| `kube_pod_container_status_restarts_total` | Crash-loop detection |
| `kube_deployment_status_replicas_ready` | How many pods are ready |

---

### 3.6 Grafana — Visualization

**What it is:** A dashboard tool that queries Prometheus with PromQL and renders charts.

**How dashboards are provisioned automatically:**

```
1. We create a ConfigMap with the dashboard JSON
2. We label it: grafana_dashboard: "1"
3. Grafana's sidecar container watches for ConfigMaps with that label
4. Sidecar copies the JSON into Grafana's dashboard folder
5. Dashboard appears in Grafana UI — no manual import needed
```

**Our dashboard panels (in `monitoring/dashboards/sample-app-dashboard.json`):**

| Panel | PromQL used | What you see |
|-------|-------------|-------------|
| Ready Pods (prod) | `kube_deployment_status_replicas_ready` | Green = all pods up |
| CPU by namespace | `rate(container_cpu_usage_seconds_total[5m])` | Line chart per env |
| Memory by namespace | `container_memory_working_set_bytes` | Line chart per env |
| Request rate | `rate(http_requests_total[5m])` | Requests/sec split by status code |
| Latency P50/P95/P99 | `histogram_quantile(0.99, ...)` | Tail latency trends |
| Restart count | `rate(kube_pod_container_status_restarts_total[15m])` | Crash-loop spikes |

---

### 3.7 Alertmanager — Alert Routing

**What it is:** Receives firing alerts from Prometheus and routes them to the right
channel (Slack, email, PagerDuty) with deduplication and grouping.

**The alert lifecycle:**

```
Prometheus evaluates rule every 30s
    │
    ├─► Rule condition TRUE for < 5min → "Pending" (not yet an alert)
    │
    └─► Rule condition TRUE for ≥ 5min → "Firing" → sent to Alertmanager
                                              │
                                    Alertmanager deduplicates,
                                    groups related alerts,
                                    waits group_wait (10s),
                                    sends to Slack/email
```

**Our alert rules (in `monitoring/alerting-rules/app-alerts.yaml`):**

```
Availability:
  SampleAppDown          → critical if no pods respond for 2 min
  SampleAppHighErrorRate → critical if 5xx rate > 5% for 5 min

Resources:
  SampleAppHighCPU       → warning if CPU > 80% for 10 min
  SampleAppHighMemory    → warning if memory > 85% of limit for 5 min
  SampleAppMemoryOOMRisk → critical if memory > 95% of limit for 2 min

Pod Health:
  SampleAppPodCrashLooping → critical if restart rate > 1/min
  SampleAppPodsNotReady    → warning if ready < desired for 5 min

Autoscaling:
  SampleAppHPAMaxReplicas  → warning if HPA is at max (can't scale further)
```

---

### 3.8 NGINX Ingress — External Access

**What it is:** A reverse proxy that runs inside Kubernetes and routes external
HTTP traffic to the right internal service based on the hostname.

**How traffic flows (when you open http://argocd.local in a browser):**

```
Browser
  │
  │  DNS lookup: argocd.local → your /etc/hosts → Minikube IP
  │
  ▼
Minikube IP:30080 (NodePort)
  │
  ▼
NGINX Ingress Controller (pod in ingress-nginx namespace)
  │
  │  Reads Ingress rules: "argocd.local → argocd-server:80"
  │
  ▼
argocd-server Service (ClusterIP in argocd namespace)
  │
  ▼
ArgoCD Server Pod
```

**Our Ingress routing table (`ingress/ingress-resources.yaml`):**

| Host | Routes to | Namespace |
|------|-----------|-----------|
| `argocd.local` | `argocd-server:80` | argocd |
| `grafana.local` | `kube-prom-stack-grafana:80` | monitoring |
| `app.dev.local` | `sample-app:80` | dev |
| `app.staging.local` | `sample-app:80` | staging |
| `app.prod.local` | `sample-app:80` | prod |

**Why NodePort and not LoadBalancer?**
Minikube runs locally with no cloud provider. NodePort exposes a port directly
on the Minikube VM (30080). In a real cloud cluster you'd use `type: LoadBalancer`
which provisions a cloud load balancer automatically.

---

## 4. Repository Structure Explained

```
ARGOCD-WORKFLOW/  (= the Git repo ArgoCD watches)
│
│  ← BOOTSTRAP LAYER (run once by a human, never by ArgoCD)
├── bootstrap/
│   ├── 01-minikube-setup.sh   ← Creates cluster + namespaces
│   ├── 02-install-argocd.sh   ← Installs ArgoCD via Helm
│   ├── 03-install-monitoring.sh ← Installs kube-prometheus-stack
│   ├── 04-install-ingress.sh  ← Installs NGINX ingress
│   └── 05-bootstrap-gitops.sh ← Plants the App-of-Apps seed
│
│  ← ARGOCD LAYER (ArgoCD reads these to know what apps to manage)
├── argocd/
│   ├── app-of-apps.yaml       ← The ONE manifest applied manually
│   ├── projects/              ← AppProject: RBAC + source repo + destinations
│   │   ├── dev-project.yaml
│   │   ├── staging-project.yaml
│   │   └── prod-project.yaml
│   └── applications/          ← Child Application CRs (created by App-of-Apps)
│       ├── dev/sample-app-dev.yaml
│       ├── staging/sample-app-staging.yaml
│       └── prod/sample-app-prod.yaml
│
│  ← APPLICATION LAYER (Kustomize manifests ArgoCD applies to the cluster)
├── apps/
│   └── sample-app/
│       ├── base/              ← Shared base (deployment, service, SA, SM)
│       └── overlays/          ← Per-env patches
│           ├── dev/           ← 1 replica, debug, low resources
│           ├── staging/       ← 2 replicas, info, medium resources
│           └── prod/          ← 3 replicas + HPA, warn, high resources
│
│  ← HELM CHART LAYER (alternative to Kustomize, same app)
├── helm-charts/sample-app/
│   ├── values.yaml            ← Defaults
│   ├── values-dev.yaml        ← Dev overrides
│   ├── values-staging.yaml    ← Staging overrides
│   └── values-prod.yaml       ← Prod overrides
│
│  ← MONITORING LAYER (Prometheus rules + Grafana dashboards)
├── monitoring/
│   ├── kube-prometheus-values.yaml  ← Helm values for the monitoring stack
│   ├── alerting-rules/              ← PrometheusRule CRs (alert conditions)
│   └── dashboards/                  ← Grafana dashboard JSON + ConfigMaps
│
│  ← NETWORKING LAYER
├── ingress/ingress-resources.yaml   ← Ingress objects for all services
│
│  ← SECURITY LAYER
├── security/
│   ├── rbac/                  ← Role + RoleBinding + ResourceQuota per namespace
│   └── sealed-secrets/        ← How to encrypt secrets for Git storage
│
│  ← CI/CD LAYER (GitHub Actions)
└── ci/workflows/
    ├── ci.yaml                ← Build → test → push image → update dev tag
    └── promote.yaml           ← Promotion: dev→staging (direct) / staging→prod (PR)
```

**The key insight:** Everything above `bootstrap/` is managed by ArgoCD.
You never run `kubectl apply` manually for anything in `apps/`, `argocd/applications/`,
`monitoring/`, `ingress/`, or `security/` — ArgoCD handles all of it.

---

## 5. The App-of-Apps Pattern

This is the most important architectural concept in the project.

**The problem it solves:**
If you have 10 applications × 3 environments = 30 ArgoCD Application CRs to manage,
manually applying them is tedious and error-prone. Who applies them? When? What if one is missing?

**The solution:**
Apply one "root" Application that watches a folder of other Application definitions.
ArgoCD then creates all the child Applications automatically.

```
You apply manually (once):          ArgoCD creates automatically:
┌─────────────────────┐             ┌──────────────────────┐
│   root-app-of-apps  │──watches──►│  argocd/applications/│
│   (Application CR)  │            │  ├── dev/             │──►  sample-app-dev
└─────────────────────┘            │  │   └── *.yaml       │
                                   │  ├── staging/         │──►  sample-app-staging
                                   │  │   └── *.yaml       │
                                   │  └── prod/            │──►  sample-app-prod
                                   │      └── *.yaml       │
                                   └──────────────────────┘
```

**What happens when you add a new app:**
1. Create `argocd/applications/dev/new-service-dev.yaml` in Git
2. Commit and push
3. ArgoCD sees the root app is OutOfSync (new file appeared)
4. Root app syncs → new Application CR created in the cluster
5. New Application CR starts syncing the new service — automatically

You never touch `kubectl` for this. Git commit = deployment.

---

## 6. End-to-End Deployment Flow

This is the complete journey from a developer writing code to it running in the cluster.

### Step 1: Developer writes code and pushes

```bash
# Developer edits their service
vim src/main.go

# Commits and pushes to the application repo (NOT the GitOps repo)
git add . && git commit -m "feat: add new endpoint"
git push origin feature/new-endpoint
# → PR merged to main
```

### Step 2: GitHub Actions CI pipeline runs (`ci/workflows/ci.yaml`)

```
Trigger: push to main
│
├── Job: build-test
│   ├── docker build -t ghcr.io/bonganiajay26/sample-app:abc1234 .
│   ├── Run tests
│   └── docker push ghcr.io/bonganiajay26/sample-app:abc1234
│
└── Job: update-dev (runs after build-test succeeds)
    ├── git clone the GitOps repo (this repo)
    ├── cd apps/sample-app/overlays/dev
    ├── kustomize edit set image ...=ghcr.io/.../sample-app:abc1234
    │   (updates the newTag field in kustomization.yaml)
    ├── git commit -m "chore(dev): update sample-app to abc1234"
    └── git push
    → The GitOps repo is now updated
```

### Step 3: ArgoCD detects the change

```
ArgoCD polls GitHub every 3 minutes (or gets webhook immediately):
│
├── Repo Server clones the updated GitOps repo
├── Runs: kustomize build apps/sample-app/overlays/dev
├── Renders the Deployment with image: ghcr.io/.../sample-app:abc1234
├── Compares with what's running in dev namespace
├── Finds: image tag differs (old: 1.0 → new: abc1234)
└── Reports: OutOfSync
```

### Step 4: ArgoCD applies the change (dev auto-syncs)

```
Because dev has automated.sync = true:
│
├── kubectl apply (rendered manifests) -n dev
├── Kubernetes receives: Deployment update (new image tag)
├── Kubernetes starts rolling update:
│   ├── Schedules new pod with new image
│   ├── Waits for readinessProbe to pass (GET / → 200 OK)
│   ├── Old pod removed (maxUnavailable: 0 = zero downtime)
│   └── Rolling update complete
└── ArgoCD reports: Synced + Healthy
```

### Step 5: Prometheus detects the new pod

```
New pod starts → exposes /metrics on port 8080
│
ServiceMonitor tells Prometheus: "scrape pods matching app.kubernetes.io/name=sample-app"
│
Prometheus discovers new pod via Kubernetes service discovery
│
First scrape: 30s after pod becomes Ready
│
Metrics start flowing into Prometheus TSDB
```

---

## 7. Multi-Environment Strategy

### How the same app behaves differently per environment

The base Deployment is identical. Only the overlays differ:

```
                    base/deployment.yaml
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
   dev overlay       staging overlay    prod overlay
   ─────────────    ──────────────     ─────────────
   replicas: 1       replicas: 2        replicas: 3
   cpu: 25m          cpu: 50m           cpu: 100m
   mem: 32Mi         mem: 64Mi          mem: 128Mi
   LOG_LEVEL: debug  LOG_LEVEL: info    LOG_LEVEL: warn
   no HPA            no HPA             HPA (3-10 pods)
   no antiAffinity   no antiAffinity    podAntiAffinity
```

### Why these differences matter

| Setting | Dev | Staging | Prod |
|---------|-----|---------|------|
| **replicas** | 1 (save resources) | 2 (test rolling updates) | 3+ (availability) |
| **CPU/memory** | Low (many devs share Minikube) | Medium (realistic test) | High (real load) |
| **LOG_LEVEL** | debug (verbose troubleshooting) | info (normal) | warn (less noise, faster) |
| **HPA** | Off (stable for debugging) | Off (predictable) | On (handle real traffic) |
| **podAntiAffinity** | Off | Off | On (spread across nodes) |

### Namespace isolation

Each environment runs in its own namespace. This means:
- `kubectl get pods -n dev` only shows dev pods
- Network policies can block staging from talking to prod
- ResourceQuota limits prevent dev from starving prod
- RBAC gives developers full access to dev, read-only to prod

---

## 8. Promotion Pipeline

### The promotion model: immutable image tags

We never use `:latest`. Every build produces a unique tag (the Git commit SHA).
This tag flows through environments as a promotion.

```
Build produces: ghcr.io/bonganiajay26/sample-app:abc1234
                                                    │
                  ┌─────────────────────────────────┤
                  ▼                                 │
         dev kustomization.yaml          Never changes in Git
         newTag: "abc1234"         ←────────────────┘
                  │
          Promoted to staging
                  │
         staging kustomization.yaml
         newTag: "abc1234"
                  │
          PR opened for prod
                  │
         prod kustomization.yaml
         newTag: "abc1234"         ← only after PR merged + manual ArgoCD sync
```

### Dev → Staging promotion (`ci/workflows/promote.yaml`)

```
Trigger: Manual (GitHub Actions workflow_dispatch)
Input: source=dev, target=staging, tag=abc1234
│
├── Read tag from dev overlay (or use provided tag)
├── Update staging overlay: kustomize edit set image ...=abc1234
├── Update annotation: gitops.io/promoted-from: dev
├── git commit + git push
└── ArgoCD detects staging change → auto-syncs staging
```

### Staging → Prod promotion (PR-gated)

```
Trigger: Manual (GitHub Actions workflow_dispatch)
Input: source=staging, target=prod, tag=abc1234
│
├── Update prod overlay with new tag
├── Update annotation: gitops.io/promoted-from: staging
├── Create Pull Request (NOT a direct push):
│   Title: "chore(prod): promote sample-app to abc1234"
│   Reviewers: sre-team
│   Body: includes checklist (staging tests, load test, on-call notification)
│
└── Human reviews + merges PR
    │
    ArgoCD detects prod overlay changed → shows OutOfSync
    │
    SRE manually triggers sync in ArgoCD UI (within sync window)
    │
    Prod deployment begins (rolling update, maxUnavailable=0)
```

### Why prod requires a manual sync (not auto-sync)

Production is the highest-risk environment. Even if Git is updated,
we want a human to:
1. Verify staging is healthy after the promotion
2. Choose the right time to deploy (not 3 AM)
3. Monitor the deployment actively
4. Be ready to roll back within seconds if something goes wrong

The sync window policy (`Mon–Fri 09:00–17:00`) reinforces this — no accidental
deploys happen on weekends or overnight.

---

## 9. Monitoring & Observability Flow

### The complete metrics pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                      METRICS PIPELINE                               │
│                                                                     │
│  sample-app pod                                                     │
│  └── /metrics endpoint (port 8080)                                 │
│         │                                                           │
│         │  HTTP GET /metrics every 30s                             │
│         ▼                                                           │
│  Prometheus                                                         │
│  └── stores time-series data (metric_name{labels} = value)        │
│         │                                                           │
│         │  PromQL query (on schedule, e.g. every 30s)             │
│         ▼                                                           │
│  Alert Rules (PrometheusRule CRs)                                  │
│  └── if condition true for N minutes → fire alert                 │
│         │                                                           │
│         │  HTTPS POST alerts to Alertmanager                      │
│         ▼                                                           │
│  Alertmanager                                                       │
│  └── deduplicate, group, silence, route                           │
│         │                                                           │
│         ├── critical alerts → #alerts-critical Slack channel      │
│         └── warning alerts  → #alerts-warnings Slack channel      │
│                                                                     │
│  Grafana                                                            │
│  └── queries Prometheus via PromQL                                 │
│  └── renders charts in dashboards                                  │
│  └── humans watch dashboards during deploys                       │
└─────────────────────────────────────────────────────────────────────┘
```

### How ServiceMonitor connects Prometheus to your app

Without the Prometheus Operator, you'd edit a `prometheus.yml` config file every
time you add a new service. The Operator introduces Custom Resources:

```
You create:                    Operator reads:          Prometheus gets:
ServiceMonitor CR  ──────►    Prometheus Operator  ──►  Updated scrape config
(your YAML file)              (watches CRs)             (no restart needed)
```

Our ServiceMonitor in `apps/sample-app/base/servicemonitor.yaml` tells Prometheus:
"Find any Service with label `app.kubernetes.io/name: sample-app` and scrape its
`http` port at `/metrics` every 30 seconds."

The label `release: kube-prometheus-stack` on the ServiceMonitor is critical —
it must match the Prometheus CR's `serviceMonitorSelector` or Prometheus ignores it.

---

## 10. Security Model

### RBAC — Who can do what

```
                    dev namespace    staging namespace    prod namespace
                    ─────────────    ─────────────────    ──────────────
dev-team group      Full access      Read-only            Read-only
qa-team group       Read-only        Sync only            No access
sre-team group      Full access      Full access          Full access (no delete)
ArgoCD SA           Full access      Full access          Full access
```

**Key prod restriction:** Nobody can `kubectl exec` into prod pods.
If you need to debug, use `kubectl debug` with ephemeral containers instead,
which creates an audit trail.

### ResourceQuota and LimitRange (prod namespace)

```yaml
ResourceQuota:          # cluster-wide cap for the namespace
  requests.cpu: "4"
  requests.memory: 4Gi
  pods: "20"

LimitRange:             # default + max per container
  default cpu:  200m    # applied if container has no resources spec
  max cpu:      2       # hard ceiling, can't exceed this
```

This prevents a misconfigured deployment from consuming all cluster resources
and starving other workloads.

### Sealed Secrets — committing secrets safely

Plain Kubernetes Secrets are base64-encoded — anyone with repo access can decode them.
Sealed Secrets encrypts with the cluster's public key so only that cluster can decrypt.

```
Developer creates Secret → kubeseal encrypts → SealedSecret committed to Git
                                                        │
                                               ArgoCD applies SealedSecret
                                                        │
                                               Sealed Secrets controller
                                               decrypts → creates real Secret
                                               (never stored in Git)
```

---

## 11. How Everything Connects — Master Data Flow

```
╔══════════════════════════════════════════════════════════════════════════╗
║                     COMPLETE SYSTEM DATA FLOW                          ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                        ║
║  1. DEVELOPER PUSHES CODE                                              ║
║     └── git push → github.com/bonganiajay26/sample-app               ║
║                                                                        ║
║  2. GITHUB ACTIONS CI (ci/workflows/ci.yaml)                           ║
║     ├── docker build + push → ghcr.io/.../sample-app:abc1234         ║
║     └── update GitOps repo: overlays/dev/kustomization.yaml           ║
║         newTag: "abc1234"                                              ║
║                                                                        ║
║  3. GITOPS REPO UPDATED                                                ║
║     └── github.com/bonganiajay26/argocd-gitops (this repo)           ║
║                                                                        ║
║  4. ARGOCD DETECTS CHANGE (every 3 min)                                ║
║     ├── Repo Server clones GitOps repo                                ║
║     ├── kustomize build overlays/dev → rendered YAML                  ║
║     ├── compare with live cluster state                                ║
║     └── diff found → OutOfSync                                         ║
║                                                                        ║
║  5. ARGOCD APPLIES (dev auto-syncs, staging auto-syncs, prod manual)  ║
║     └── kubectl apply -n dev → Deployment updated                     ║
║                                                                        ║
║  6. KUBERNETES ROLLING UPDATE                                          ║
║     ├── Schedule new pod (new image)                                   ║
║     ├── Wait for readinessProbe pass                                   ║
║     ├── Terminate old pod (zero downtime)                              ║
║     └── Deployment status: Available                                   ║
║                                                                        ║
║  7. PROMETHEUS SCRAPES NEW POD                                         ║
║     └── /metrics → CPU, memory, request rate, latency → TSDB         ║
║                                                                        ║
║  8. GRAFANA VISUALIZES                                                 ║
║     └── PromQL queries → charts on sample-app dashboard               ║
║                                                                        ║
║  9. ALERTMANAGER FIRES (if thresholds breached)                        ║
║     └── PrometheusRule condition true > N min → Slack alert           ║
║                                                                        ║
║  10. PROMOTION (manual trigger)                                        ║
║      ├── dev → staging: CI updates staging tag, ArgoCD auto-syncs     ║
║      └── staging → prod: CI opens PR, SRE reviews+merges,            ║
║                          ArgoCD shows OutOfSync,                       ║
║                          SRE manually syncs in UI (within window)     ║
╚══════════════════════════════════════════════════════════════════════════╝
```

### Component dependency map

```
GitHub Repo (GitOps)
    │
    │ polls
    ▼
ArgoCD Repo Server
    │
    │ renders (kustomize/helm)
    ▼
ArgoCD App Controller ──────────────────────────► Kubernetes API
    │                                                   │
    │ creates/updates                                   │ schedules
    ▼                                                   ▼
Application CRs                                    Pods (sample-app)
(dev, staging, prod)                                    │
                                                        │ exposes
                                                        ▼
                                               /metrics endpoint
                                                        │
                                                        │ scrapes
                                                        ▼
                                                  Prometheus
                                                  ├── stores TSDB
                                                  ├── evaluates rules
                                                  └── fires → Alertmanager
                                                              └── → Slack

                                                  Grafana
                                                  └── queries Prometheus
                                                      └── renders dashboards

                                                  NGINX Ingress
                                                  └── routes external traffic
                                                      to any of the above
```

---

## Quick Reference: "What do I look at when X goes wrong?"

| Problem | Where to look |
|---------|--------------|
| App not deploying | ArgoCD UI → app status → sync errors |
| App deployed but crashing | `kubectl logs -n dev pod/sample-app-xxx` |
| App slow or erroring | Grafana → Sample App dashboard → latency/error panels |
| Alert firing | Alertmanager UI (localhost:9093) → active alerts |
| Metrics missing | Prometheus UI (localhost:9090) → Status → Targets |
| ArgoCD not syncing | `kubectl logs -n argocd deployment/argocd-repo-server` |
| Prod deployment needed | ArgoCD UI → sample-app-prod → Sync (within Mon–Fri 09–17) |
| Emergency rollback | `git revert HEAD~1 && git push` → ArgoCD re-syncs old version |
