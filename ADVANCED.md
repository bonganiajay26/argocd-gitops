# Advanced Enhancements

## 1. Progressive Delivery with Argo Rollouts

Argo Rollouts replaces standard Deployments with canary/blue-green strategies.

### Install

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Install kubectl plugin
brew install argoproj/tap/kubectl-argo-rollouts
```

### Canary Rollout Manifest

```yaml
# Replace apps/sample-app/base/deployment.yaml with this Rollout
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: sample-app
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: sample-app
  template:
    # same pod template as Deployment
    metadata:
      labels:
        app.kubernetes.io/name: sample-app
    spec:
      containers:
        - name: sample-app
          image: gcr.io/google-samples/hello-app:1.0
          ports:
            - containerPort: 8080
  strategy:
    canary:
      steps:
        - setWeight: 10        # route 10% traffic to canary
        - pause: {duration: 2m}
        - setWeight: 30
        - pause: {duration: 2m}
        - analysis:             # run analysis before continuing
            templates:
              - templateName: success-rate
        - setWeight: 60
        - pause: {duration: 1m}
        - setWeight: 100        # full rollout
      canaryService: sample-app-canary
      stableService: sample-app-stable
      trafficRouting:
        nginx:
          stableIngress: sample-app-prod-ingress
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
    - name: success-rate
      interval: 30s
      successCondition: result[0] >= 0.95
      failureLimit: 3
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{job="sample-app",status!~"5.."}[5m]))
            /
            sum(rate(http_requests_total{job="sample-app"}[5m]))
```

### Monitor a Rollout

```bash
kubectl argo rollouts get rollout sample-app -n prod --watch
kubectl argo rollouts promote sample-app -n prod   # manually advance
kubectl argo rollouts abort sample-app -n prod     # abort → automatic rollback
```

---

## 2. Policy Enforcement with OPA/Gatekeeper

Gatekeeper enforces policies at admission time — blocks non-compliant workloads
before they reach the cluster.

### Install

```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace
```

### Example: Require resource limits on all containers

```yaml
# ConstraintTemplate defines the policy schema
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: requireresourcelimits
spec:
  crd:
    spec:
      names:
        kind: RequireResourceLimits
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package requireresourcelimits
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.cpu
          msg := sprintf("Container '%v' must have a CPU limit", [container.name])
        }
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.memory
          msg := sprintf("Container '%v' must have a memory limit", [container.name])
        }
---
# Constraint activates the policy
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RequireResourceLimits
metadata:
  name: require-resource-limits
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
    namespaces: ["dev", "staging", "prod"]
  enforcementAction: deny    # use "warn" to audit without blocking
```

### Example: Disallow latest image tag

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: bannedimagetags
spec:
  crd:
    spec:
      names:
        kind: BannedImageTags
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package bannedimagetags
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          endswith(container.image, ":latest")
          msg := sprintf("Container '%v' must not use ':latest' tag", [container.name])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: BannedImageTags
metadata:
  name: no-latest-tag
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet", "DaemonSet"]
    namespaces: ["staging", "prod"]
  enforcementAction: deny
```

---

## 3. GitHub Actions + ArgoCD Image Updater (Alternative to kustomize edit)

ArgoCD Image Updater polls container registries and auto-updates image tags
in Git — eliminating the CI "kustomize edit + git push" step.

### Install

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --set config.argocd.plaintext=true
```

### Annotate the ArgoCD Application

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: >
      app=ghcr.io/bonganiajay26/sample-app
    argocd-image-updater.argoproj.io/app.update-strategy: latest
    argocd-image-updater.argoproj.io/app.tag-match: regexp:^[0-9a-f]{7}$
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
```

Image Updater then commits tag changes directly to the GitOps repo — no CI
step needed for image promotion to dev.

---

## 4. Multi-Cluster Setup (Production Extension)

When you grow beyond Minikube:

```bash
# Register external cluster with ArgoCD
argocd cluster add <context-name>   # adds cluster to ArgoCD

# Update Application destination
spec:
  destination:
    server: https://prod-cluster.k8s.example.com   # external cluster URL
    namespace: prod
```

ApplicationSets make multi-cluster deployments declarative:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: sample-app-clusters
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            environment: prod    # deploy to all clusters labelled environment=prod
  template:
    metadata:
      name: '{{name}}-sample-app'
    spec:
      project: prod
      source:
        repoURL: https://github.com/bonganiajay26/argocd-gitops.git
        path: apps/sample-app/overlays/prod
        targetRevision: main
      destination:
        server: '{{server}}'
        namespace: prod
```
