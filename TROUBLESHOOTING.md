# Real-World Troubleshooting Guide — GitOps Platform

> Every issue documented here was encountered in real deployments.
> Each entry includes: what you see, why it happens, and exactly how to fix it.

---

## Table of Contents

1. [Minikube Issues](#1-minikube-issues)
2. [ArgoCD Issues](#2-argocd-issues)
3. [Kustomize & Helm Issues](#3-kustomize--helm-issues)
4. [Kubernetes Pod & Deployment Issues](#4-kubernetes-pod--deployment-issues)
5. [Prometheus & Monitoring Issues](#5-prometheus--monitoring-issues)
6. [Grafana Issues](#6-grafana-issues)
7. [Alertmanager Issues](#7-alertmanager-issues)
8. [NGINX Ingress Issues](#8-nginx-ingress-issues)
9. [GitHub Actions CI/CD Issues](#9-github-actions-cicd-issues)
10. [RBAC & Security Issues](#10-rbac--security-issues)
11. [Networking & DNS Issues](#11-networking--dns-issues)
12. [Performance & Resource Issues](#12-performance--resource-issues)
13. [Real Issues We Hit in This Project](#13-real-issues-we-hit-in-this-project)

---

## 1. Minikube Issues

---

### 1.1 Minikube Fails to Start

**Symptoms:**
```
❌ Exiting due to GUEST_PROVISION: Failed to start host: ...
❌ Unable to pick a default driver
```

**Causes & Fixes:**

**A) Docker not running**
```bash
# Check Docker
docker info

# Fix: start Docker Desktop, then retry
minikube start --driver=docker
```

**B) Not enough resources**
```bash
# Reduce resource request
minikube start --cpus=2 --memory=4096

# Or free up Docker resources:
# Docker Desktop → Settings → Resources → increase CPU/RAM
```

**C) Old cluster state corrupted**
```bash
minikube delete --profile gitops-platform
minikube start --profile gitops-platform --driver=docker --cpus=4 --memory=8192
```

---

### 1.2 Minikube IP Changes After Restart

**Symptoms:**
```
curl: (6) Could not resolve host: argocd.local
Browser: This site can't be reached
```

**Why it happens:** Minikube picks a new IP from the Docker network pool on each start.

**Fix:**
```bash
# Get new IP
MINIKUBE_IP=$(minikube ip --profile gitops-platform)
echo $MINIKUBE_IP

# Update /etc/hosts (Linux/macOS)
sudo sed -i.bak \
  "s/^[0-9.]* argocd\.local.*/${MINIKUBE_IP}  argocd.local grafana.local app.dev.local app.staging.local app.prod.local/" \
  /etc/hosts

# Windows (run PowerShell as Admin)
$ip = minikube ip --profile gitops-platform
$content = Get-Content C:\Windows\System32\drivers\etc\hosts
$content = $content -replace '^\d+\.\d+\.\d+\.\d+\s+argocd\.local.*', "$ip  argocd.local grafana.local app.dev.local app.staging.local app.prod.local"
$content | Set-Content C:\Windows\System32\drivers\etc\hosts
```

---

### 1.3 `kubectl top nodes` Returns No Metrics

**Symptoms:**
```
error: Metrics API not available
```

**Why:** metrics-server addon not enabled or not healthy.

**Fix:**
```bash
# Enable addon
minikube addons enable metrics-server --profile gitops-platform

# Wait for it to be ready
kubectl rollout status deployment/metrics-server -n kube-system --timeout=60s

# Verify
kubectl top nodes
kubectl top pods -A
```

---

### 1.4 Minikube Disk Full

**Symptoms:**
```bash
kubectl describe pod <any-pod>
# Events: Warning  FreeDiskSpaceFailed
# Status: Evicted
```

**Fix:**
```bash
# Check disk usage inside Minikube VM
minikube ssh -- df -h

# Remove unused Docker images inside the VM
minikube ssh -- docker system prune -af

# Remove unused Kubernetes images
minikube ssh -- crictl rmi --prune

# If still full, increase disk and recreate cluster
minikube delete --profile gitops-platform
minikube start --profile gitops-platform --disk-size=60g
```

---

### 1.5 Minikube Addons Not Working After Restart

**Symptoms:** `minikube addons list` shows addon as enabled but it's not functioning.

**Fix:**
```bash
# Re-enable all needed addons
minikube addons enable metrics-server       --profile gitops-platform
minikube addons enable storage-provisioner  --profile gitops-platform
minikube addons enable default-storageclass --profile gitops-platform

# Restart addon pods
kubectl rollout restart deployment/metrics-server -n kube-system
```

---

## 2. ArgoCD Issues

---

### 2.1 `htpasswd: command not found` During ArgoCD Install

**Symptoms:** (We hit this exact error in this project)
```
bootstrap/02-install-argocd.sh: line 18: htpasswd: command not found
```

**Why:** `htpasswd` is part of `apache2-utils` (Linux) / `httpd-tools` (macOS via brew).
On Windows/Git Bash it's often not installed.

**Fix A — Install htpasswd:**
```bash
# macOS
brew install httpd

# Ubuntu/Debian
sudo apt-get install apache2-utils

# Windows (via Git Bash + choco)
choco install apache-httpd
```

**Fix B — Use ArgoCD's auto-generated password instead (what we did):**
```bash
# Skip the --set configs.secret.argocdServerAdminPassword= flag
# ArgoCD generates a random password and stores it in a secret
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

### 2.2 ArgoCD App Shows "ComparisonError: repository not found"

**Symptoms:** (We hit this exact error in this project)
```
Message: Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = repository not found
```

**Why:** The Application CR has a placeholder URL (`REPO_URL_PLACEHOLDER`) instead of
the real repo URL, OR the repo is private and no credentials are registered.

**Fix A — Placeholder not replaced (our case):**
```bash
# Check what URL is stored in the Application
kubectl get application root-app-of-apps -n argocd \
  -o jsonpath='{.spec.source.repoURL}'

# If it shows REPO_URL_PLACEHOLDER, edit the file and re-apply
# argocd/app-of-apps.yaml → set real URL
kubectl apply -f argocd/app-of-apps.yaml
```

**Fix B — Private repo, no credentials:**
```bash
# Register repo with HTTPS token
argocd repo add https://github.com/org/repo.git \
  --username git \
  --password <github-personal-access-token>

# Or with SSH key
argocd repo add git@github.com:org/repo.git \
  --ssh-private-key-path ~/.ssh/id_rsa
```

---

### 2.3 App-of-Apps Synced But No Child Apps Created

**Symptoms:** (We hit this exact error in this project)
```
NAME               SYNC STATUS   HEALTH STATUS
root-app-of-apps   Synced        Healthy
# No child apps appear
```

**Why:** ArgoCD does NOT recurse into subdirectories by default.
Child apps in `argocd/applications/dev/`, `argocd/applications/staging/` etc.
are invisible without `directory.recurse: true`.

**Fix — Add recurse to app-of-apps source:**
```yaml
# argocd/app-of-apps.yaml
spec:
  source:
    path: argocd/applications
    directory:
      recurse: true        ← add this
```
```bash
kubectl apply -f argocd/app-of-apps.yaml
```

---

### 2.4 ArgoCD CLI Not Found

**Symptoms:** (We hit this exact error in this project)
```
bootstrap/05-bootstrap-gitops.sh: line 22: argocd: command not found
```

**Fix:**
```bash
# macOS
brew install argocd

# Linux
curl -sSL -o argocd-linux-amd64 \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd

# Windows (via winget)
winget install ArgoProj.ArgoCD

# Verify
argocd version --client
```

---

### 2.5 Port 8080 Already in Use When Running Port-Forward

**Symptoms:** (We hit this exact error in this project)
```
Unable to listen on port 8080: Listeners failed to create with the following errors:
[unable to create listener: Error listen tcp4 127.0.0.1:8080: bind: Only one usage
of each socket address ...]
```

**Why:** A previous `kubectl port-forward` or another process is already bound to 8080.

**Fix:**
```bash
# Find what's using port 8080
# macOS/Linux
lsof -i :8080
kill -9 <PID>

# Windows (PowerShell)
netstat -ano | findstr :8080
taskkill /PID <PID> /F

# Or use a different local port
kubectl port-forward svc/argocd-server -n argocd 8081:80 &
argocd login localhost:8081 --username admin --password <pass> --insecure
```

---

### 2.6 ArgoCD Login: "Invalid username or password"

**Why:** Three possible reasons:
1. You're using the old initial secret password after changing it
2. The admin password was set via Helm `--set` but `htpasswd` failed silently
3. You're using the Helm-set password but ArgoCD generated its own

**Fix:**
```bash
# Always get the current password from the secret
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo

# If initial secret was deleted (ArgoCD recommends this after first login),
# reset the password:
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": "<bcrypt-hash>", "admin.passwordMtime": "now"}}'

# Or use argocd CLI to update password after logging in via UI token:
argocd account update-password \
  --current-password <old> \
  --new-password <new>
```

---

### 2.7 App Stuck in "Progressing" Health Status

**Symptoms:**
```
NAME            SYNC STATUS   HEALTH STATUS
sample-app-dev  Synced        Progressing   ← never becomes Healthy
```

**Why:** The Deployment is stuck — pods aren't becoming Ready.

**Fix:**
```bash
# 1. Check what ArgoCD sees
kubectl describe application sample-app-dev -n argocd

# 2. Check the actual pods
kubectl get pods -n dev
kubectl describe pod <pod-name> -n dev   # look at Events section

# 3. Common causes:
#    - Image pull error  → check image name/tag and registry credentials
#    - CrashLoopBackOff  → check logs: kubectl logs <pod> -n dev --previous
#    - Insufficient resources → kubectl describe node minikube | grep -A5 "Allocated"
#    - Readiness probe failing → check probe path and port
```

---

### 2.8 ArgoCD Shows "OutOfSync" Even After Sync

**Why:** Something in the cluster is mutating the resource after ArgoCD applies it
(e.g., admission webhooks adding annotations, the HPA controller changing replica count).

**Fix — Add ignoreDifferences to the Application:**
```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas              # HPA manages this
        - /spec/template/metadata/annotations  # webhook injects these
    - group: autoscaling
      kind: HorizontalPodAutoscaler
      jsonPointers:
        - /spec/minReplicas
        - /spec/maxReplicas
```

---

### 2.9 ArgoCD Sync Window Blocking Deployment

**Symptoms:**
```
# In ArgoCD UI: "Sync not allowed at this time (sync window)"
Sync operation failed: Blocked by sync window
```

**Why:** The prod AppProject has sync windows (`Mon–Fri 09:00–17:00`).
Any sync attempt outside that window is blocked.

**Fix — Check active windows:**
```bash
kubectl get appproject prod -n argocd -o yaml | grep -A 10 syncWindows

# Override for emergencies (requires admin):
argocd proj windows disable prod   # temporarily disable
argocd app sync sample-app-prod
argocd proj windows enable prod    # re-enable
```

---

## 3. Kustomize & Helm Issues

---

### 3.1 `kustomize build` Fails: "no such file or directory"

**Symptoms:**
```
Error: accumulating resources: ...no such file or directory
```

**Fix:**
```bash
# Check your kustomization.yaml resources list matches actual file names
cd apps/sample-app/overlays/dev
cat kustomization.yaml    # check 'bases' and 'resources' entries

# Verify files exist
ls ../../base/

# Run locally to debug before committing
kustomize build .
```

---

### 3.2 Kustomize Image Tag Not Updating

**Symptoms:** ArgoCD syncs but the pod still runs the old image.

**Why:** The `images:` block in kustomization.yaml uses a different image name
than what's in the base deployment.

**Fix:**
```yaml
# kustomization.yaml — image name MUST exactly match deployment.yaml
images:
  - name: gcr.io/google-samples/hello-app   # ← must match image: in deployment.yaml
    newTag: "abc1234"
```
```bash
# Verify the rendered output
kustomize build apps/sample-app/overlays/dev | grep "image:"
```

---

### 3.3 Helm Chart: "rendered manifests contain a resource that already exists"

**Symptoms:**
```
Error: rendered manifests contain a resource that already exists.
Unable to continue with install: existing resource conflict
```

**Fix:**
```bash
# Option A: Use upgrade instead of install
helm upgrade --install my-release my-chart/...

# Option B: Take ownership of the existing resource
helm upgrade --install my-release my-chart/... \
  --set-string "annotations.meta\.helm\.sh/release-name=my-release"

# Option C: Delete the conflicting resource and reinstall
kubectl delete <resource-type> <resource-name> -n <namespace>
helm install my-release my-chart/...
```

---

### 3.4 Helm Values Not Applied (Wrong Release Name)

**Symptoms:** (We hit a version of this — `kube-prometheus-stack` vs `kube-prom-stack`)

**Why:** The Helm release name determines all resource names.
If you install as `kube-prom-stack`, services are named `kube-prom-stack-grafana`,
not `kube-prometheus-stack-grafana`.

**Fix:**
```bash
# Always check the actual release name
helm list -A

# Find the actual service names
kubectl get svc -n monitoring

# Update any hardcoded references (ArgoCD applications, ingress rules, port-forwards)
# to use the actual names, not the assumed ones
```

---

## 4. Kubernetes Pod & Deployment Issues

---

### 4.1 Pod Stuck in `Pending`

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at the Events section at the bottom
```

**Cause A: Insufficient CPU/Memory**
```
Events: Warning  FailedScheduling  0/1 nodes are available:
        1 Insufficient cpu, 1 Insufficient memory.
```
```bash
# Fix: lower resource requests in the overlay patch
# OR increase Minikube resources
minikube stop --profile gitops-platform
minikube start --profile gitops-platform --cpus=6 --memory=10240
```

**Cause B: PVC not bound**
```
Events: Warning  FailedScheduling  pod has unbound PersistentVolumeClaims
```
```bash
kubectl get pvc -n <namespace>          # check status
kubectl describe pvc <pvc-name> -n <ns> # check events

# Fix: ensure StorageClass exists
kubectl get storageclass
minikube addons enable storage-provisioner --profile gitops-platform
```

**Cause C: Node taint / affinity mismatch**
```
Events: Warning  FailedScheduling  node(s) had untolerated taint
```
```bash
kubectl describe node minikube | grep Taints
# Add toleration to pod spec or remove the taint
kubectl taint node minikube <key>=<value>:NoSchedule-
```

---

### 4.2 Pod in `CrashLoopBackOff`

**Diagnosis:**
```bash
# Get logs from the crashed container
kubectl logs <pod-name> -n <namespace> --previous

# Get the exit code
kubectl describe pod <pod-name> -n <namespace> | grep "Exit Code"
```

| Exit Code | Meaning | Fix |
|-----------|---------|-----|
| 1 | App error | Check app logs, fix the bug |
| 137 | OOM killed | Increase memory limit |
| 139 | Segfault | App crash, check logs |
| 143 | SIGTERM not handled | Fix graceful shutdown |

```bash
# Fix OOM: increase memory limit in the overlay patch
# patch-deployment.yaml
resources:
  limits:
    memory: 512Mi   # was 256Mi
```

---

### 4.3 Pod in `ImagePullBackOff` / `ErrImagePull`

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: Failed to pull image "...": ...
```

**Cause A: Image doesn't exist**
```bash
# Verify the image tag exists in the registry
docker pull gcr.io/google-samples/hello-app:1.0

# Check kustomization.yaml for typos in the tag
grep newTag apps/sample-app/overlays/dev/kustomization.yaml
```

**Cause B: Private registry, no pull secret**
```bash
# Create imagePullSecret
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<personal-access-token> \
  -n dev

# Reference in serviceaccount.yaml
imagePullSecrets:
  - name: ghcr-secret
```

---

### 4.4 `readOnlyRootFilesystem: true` Causing App Crash

**Symptoms:**
```
Error: open /tmp/app.log: read-only file system
```

**Why:** We set `readOnlyRootFilesystem: true` in securityContext for hardening,
but the app tries to write to the filesystem.

**Fix — Mount an emptyDir for writable paths:**
```yaml
# deployment.yaml
spec:
  containers:
    - name: sample-app
      volumeMounts:
        - name: tmp-dir
          mountPath: /tmp
        - name: log-dir
          mountPath: /var/log/app
  volumes:
    - name: tmp-dir
      emptyDir: {}
    - name: log-dir
      emptyDir: {}
```

---

### 4.5 Rolling Update Stuck: Pods Never Become Ready

**Symptoms:**
```
kubectl rollout status deployment/sample-app -n prod
Waiting for deployment "sample-app" rollout to finish: 1 out of 3 new replicas have been updated...
# Hangs forever
```

**Cause A: Readiness probe misconfigured**
```bash
# Test the probe manually
kubectl exec -n prod <old-pod> -- curl -s http://localhost:8080/

# If app serves on different port or path, fix the probe:
readinessProbe:
  httpGet:
    path: /health    # was /, but app uses /health
    port: 8080
```

**Cause B: Insufficient resources to schedule new pod**
```bash
kubectl describe node minikube | grep -A 10 "Allocated resources"
# If close to limit, the new pod can't be scheduled
# Fix: scale down non-critical workloads or increase Minikube memory
```

---

## 5. Prometheus & Monitoring Issues

---

### 5.1 Prometheus Not Scraping the App (No Targets Found)

**Symptoms:** Prometheus UI → Status → Targets → sample-app not listed

**Cause A: ServiceMonitor label mismatch**
```bash
# Check what label Prometheus uses to find ServiceMonitors
kubectl get prometheus -n monitoring -o yaml | grep -A5 serviceMonitorSelector

# Check your ServiceMonitor has the matching label
kubectl get servicemonitor sample-app -n dev -o yaml | grep -A5 labels
# Must have: release: kube-prometheus-stack  (or whatever your selector is)
```

```yaml
# Fix: add the correct label to ServiceMonitor
metadata:
  labels:
    release: kube-prom-stack   # match your actual Helm release name
```

**Cause B: ServiceMonitor in wrong namespace**

The Prometheus CR's `serviceMonitorNamespaceSelector` controls which namespaces
it watches. Our config sets it to `{}` (all namespaces). If yours is different:

```bash
kubectl get prometheus -n monitoring -o yaml | grep -A5 serviceMonitorNamespaceSelector
# {} = all namespaces (correct)
# {matchLabels: {monitoring: enabled}} = only labelled namespaces

# Fix: label your namespace
kubectl label namespace dev monitoring=enabled
```

**Cause C: Service selector doesn't match pod labels**
```bash
# Check service selector
kubectl get svc sample-app -n dev -o yaml | grep -A5 selector

# Check pod labels
kubectl get pods -n dev --show-labels

# They must match
```

---

### 5.2 PrometheusRule Not Creating Alerts

**Symptoms:** Alerts don't appear in Prometheus UI → Alerts

**Fix:**
```bash
# Check if the rule was picked up by Prometheus
kubectl get prometheusrule -n monitoring

# Check Prometheus rule selector
kubectl get prometheus -n monitoring -o yaml | grep -A5 ruleSelector
# {} = all rules (correct)
# If selective, add matching label to your PrometheusRule

# Check rule syntax by validating locally
# Install promtool:
promtool check rules monitoring/alerting-rules/app-alerts.yaml

# Check Prometheus config reload logs
kubectl logs -n monitoring prometheus-kube-prom-stack-kube-prome-prometheus-0 \
  -c prometheus | grep -i "rule\|error"
```

---

### 5.3 Prometheus Storage Full / Data Loss

**Symptoms:**
```
level=warn ts=... msg="Head GC took longer than expected"
level=err  ts=... msg="Opening storage failed" err="unexpected end of chunk"
```

**Fix:**
```bash
# Check current storage usage
kubectl exec -n monitoring \
  prometheus-kube-prom-stack-kube-prome-prometheus-0 \
  -- df -h /prometheus

# Reduce retention (default 7d in our config)
# In monitoring/kube-prometheus-values.yaml:
prometheusSpec:
  retention: 3d        # was 7d
  retentionSize: "3GB" # was 5GB

helm upgrade kube-prom-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --values monitoring/kube-prometheus-values.yaml
```

---

## 6. Grafana Issues

---

### 6.1 Grafana "Invalid username or password"

**Why:** The password in `kube-prometheus-values.yaml` (`Grafana@2024!`) may not
match what was actually set if Helm used an existing secret or the secret was
previously created.

**Fix — Get the real password:**
```bash
# Get from Kubernetes secret (source of truth)
kubectl get secret kube-prom-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo

# If secret name differs (check your Helm release name):
kubectl get secrets -n monitoring | grep grafana
```

---

### 6.2 Grafana Dashboard Shows "No Data"

**Diagnosis steps:**
```bash
# Step 1: Verify Prometheus datasource works
# Grafana UI → Configuration → Data Sources → Prometheus → Save & Test
# Should show: "Data source is working"

# Step 2: Check if Prometheus has the metric at all
# Go to Prometheus UI (localhost:9090) → Graph
# Run: up{job="sample-app"}
# If empty → Prometheus isn't scraping (see section 5.1)

# Step 3: Check time range
# Grafana shows "No data" if time range is before metrics existed
# Change to "Last 1 hour" → if data appears, it's a time range issue

# Step 4: Check PromQL syntax
# Copy the panel query and run it directly in Prometheus UI
```

---

### 6.3 Grafana Dashboard Not Auto-Imported

**Why:** The sidecar looks for ConfigMaps with label `grafana_dashboard: "1"` but
your ConfigMap uses a different label or is in a namespace the sidecar doesn't watch.

**Fix:**
```bash
# Check sidecar config
kubectl get deployment kube-prom-stack-grafana -n monitoring -o yaml \
  | grep -A5 "LABEL\|NAMESPACE\|grafana_dashboard"

# Verify ConfigMap has correct label
kubectl get configmap -n monitoring --show-labels | grep dashboard

# If wrong label, patch it:
kubectl label configmap sample-app-grafana-dashboard \
  grafana_dashboard=1 -n monitoring

# Check sidecar logs
kubectl logs -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o name) \
  -c grafana-sc-dashboard
```

---

## 7. Alertmanager Issues

---

### 7.1 Alerts Firing in Prometheus But Not Reaching Slack

**Diagnosis:**
```bash
# Step 1: Is Alertmanager receiving alerts?
# Port-forward to Alertmanager
kubectl port-forward svc/kube-prom-stack-kube-prome-alertmanager -n monitoring 9093:9093

# Go to http://localhost:9093/#/alerts
# If alert appears here but Slack didn't get it → routing/webhook issue
# If alert doesn't appear here → check Prometheus → Alertmanager connection

# Step 2: Check Alertmanager config is valid
kubectl exec -n monitoring \
  alertmanager-kube-prom-stack-kube-prome-alertmanager-0 \
  -- amtool config show

# Step 3: Test Slack webhook manually
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test from AlertManager"}' \
  https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
```

---

### 7.2 Alert Is "Pending" Forever and Never Fires

**Why:** The `for:` duration in the rule hasn't elapsed, or the condition keeps
going true/false before the duration completes.

```yaml
# Rule fires only if condition is CONTINUOUSLY true for the full duration
- alert: SampleAppHighCPU
  expr: rate(container_cpu_usage_seconds_total[5m]) > 0.8
  for: 10m   ← must be true for 10 full minutes without interruption
```

**Fix:**
```bash
# Reduce 'for' duration for testing
for: 1m

# Or watch the alert state in Prometheus UI → Alerts
# "Pending" = condition true but 'for' not elapsed
# "Firing"  = condition true for full duration
```

---

## 8. NGINX Ingress Issues

---

### 8.1 503 Service Temporarily Unavailable

**Symptoms:** Browser shows 503 when hitting `argocd.local` or `grafana.local`

**Why:** Ingress rule exists but the backend service/pod isn't ready.

```bash
# Check ingress is configured
kubectl get ingress -A

# Check the backend service exists
kubectl get svc argocd-server -n argocd
kubectl get svc kube-prom-stack-grafana -n monitoring

# Check endpoints (must not be empty)
kubectl get endpoints argocd-server -n argocd
# If "<none>" → no pods match the service selector → pods aren't running

# Check ingress controller logs
kubectl logs -n ingress-nginx \
  $(kubectl get pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o name) \
  | tail -20
```

---

### 8.2 404 Not Found from NGINX

**Why:** The Ingress rule path or host doesn't match the request.

```bash
# Check ingress rules
kubectl describe ingress -A | grep -A5 "Rules:"

# Common causes:
# 1. /etc/hosts entry doesn't match the Ingress host exactly
# 2. Ingress className missing or wrong
kubectl get ingress argocd-ingress -n argocd -o yaml | grep ingressClassName
# Must be: nginx (matches the installed controller)

# 3. Wrong path type (Prefix vs Exact)
```

---

### 8.3 Ingress Controller Pod Not Starting

**Symptoms:**
```
kubectl get pods -n ingress-nginx
NAME                                       READY   STATUS    RESTARTS
ingress-nginx-controller-xxx               0/1     Pending   0
```

**Fix:**
```bash
kubectl describe pod -n ingress-nginx ingress-nginx-controller-xxx
# Check Events for scheduling errors

# Common cause on Minikube: NodePort conflict
# Check if ports 30080/30443 are already in use
netstat -tlnp | grep 3008

# Reinstall with different NodePorts
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --set controller.service.nodePorts.http=30090 \
  --set controller.service.nodePorts.https=30453 \
  -n ingress-nginx
```

---

## 9. GitHub Actions CI/CD Issues

---

### 9.1 CI Fails: "Permission denied to push to GitOps repo"

**Why:** The `GITOPS_PAT` secret is missing, expired, or lacks `repo` write scope.

**Fix:**
```bash
# Generate a new Personal Access Token on GitHub:
# Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
# Permissions: Contents (read + write), Pull Requests (read + write)

# Add to repo secrets:
# GitHub repo → Settings → Secrets and variables → Actions → New secret
# Name: GITOPS_PAT
# Value: <your token>
```

---

### 9.2 `kustomize edit set image` Not Found in CI

**Symptoms:**
```
/usr/bin/bash: kustomize: command not found
```

**Fix — Add kustomize install step to CI:**
```yaml
# ci/workflows/ci.yaml
- name: Install kustomize
  run: |
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" \
      | bash
    sudo mv kustomize /usr/local/bin/
```

---

### 9.3 Promote Workflow Opens PR but ArgoCD Doesn't Sync

**Why:** ArgoCD polls every 3 minutes. Even after the PR is merged, there's a delay.
Also, prod has `automated: {}` (disabled), so ArgoCD will show OutOfSync but won't auto-apply.

**Expected behavior for prod:**
```
PR merged → git commit → ArgoCD detects diff (within 3 min) → status: OutOfSync
→ SRE manually clicks Sync in ArgoCD UI (or runs: argocd app sync sample-app-prod)
→ Rolling update begins
```

**If ArgoCD never shows OutOfSync after PR merge:**
```bash
# Force a hard refresh (bypasses cache)
argocd app get sample-app-prod --hard-refresh

# Or via kubectl
kubectl annotate application sample-app-prod -n argocd \
  argocd.argoproj.io/refresh=hard
```

---

## 10. RBAC & Security Issues

---

### 10.1 `Error from server (Forbidden): pods is forbidden`

**Symptoms:**
```
Error from server (Forbidden): pods is forbidden:
User "john" cannot list resource "pods" in API group "" in the namespace "prod"
```

**Fix:**
```bash
# Check what roles the user has
kubectl get rolebindings -n prod -o yaml | grep -A5 "subjects"

# Check what the role allows
kubectl describe role prod-readonly -n prod

# Add missing permission to the Role
kubectl edit role prod-readonly -n prod
# Add the missing verb/resource combination
```

---

### 10.2 ArgoCD Can't Apply Resources (Forbidden)

**Why:** ArgoCD's ServiceAccount doesn't have permission to create the resource.

```bash
# Check ArgoCD SA permissions
kubectl get clusterrolebindings | grep argocd

# Check what failed
kubectl logs -n argocd deployment/argocd-application-controller | grep -i "forbidden\|rbac"

# ArgoCD needs ClusterAdmin or specific permissions for cluster-scoped resources
# For namespaced resources it only needs ns-scoped permissions
```

---

### 10.3 LimitRange Blocking Pod Creation

**Symptoms:**
```
Error from server (Forbidden): pods "sample-app" is forbidden:
maximum cpu usage per Container is 2, but limit is 4.
```

**Fix:**
```bash
# Check LimitRange in the namespace
kubectl describe limitrange prod-limit-range -n prod

# Fix: lower the container limit in the overlay to be within LimitRange bounds
# patch-deployment.yaml
resources:
  limits:
    cpu: "1"      # was 4, LimitRange max is 2
    memory: 512Mi
```

---

## 11. Networking & DNS Issues

---

### 11.1 `argocd.local` Not Resolving in Browser

**Symptoms:** Browser shows "This site can't be reached — DNS_PROBE_FINISHED_NXDOMAIN"

**Fix steps:**
```bash
# 1. Check /etc/hosts has the entry
cat /etc/hosts | grep argocd

# 2. If missing, add it
echo "$(minikube ip --profile gitops-platform)  argocd.local grafana.local \
  app.dev.local app.staging.local app.prod.local" | sudo tee -a /etc/hosts

# 3. Verify with ping
ping argocd.local

# 4. Verify port 30080 is accessible
curl -v http://$(minikube ip --profile gitops-platform):30080
# Should show NGINX response (even if 404)

# 5. Windows-specific: flush DNS cache
ipconfig /flushdns
```

---

### 11.2 Pods Can't Reach Each Other Across Namespaces

**Symptoms:**
```
curl: (6) Could not resolve host: sample-app.dev.svc.cluster.local
```

**Why:** Cross-namespace DNS uses the full FQDN format.

```bash
# Wrong (works only within same namespace):
curl http://sample-app/

# Correct (cross-namespace):
curl http://sample-app.dev.svc.cluster.local/
# Format: <service>.<namespace>.svc.cluster.local

# Verify DNS works inside a pod
kubectl run -it --rm debug --image=curlimages/curl --restart=Never \
  -- curl http://sample-app.dev.svc.cluster.local/
```

---

## 12. Performance & Resource Issues

---

### 12.1 ArgoCD Sync Is Very Slow (>2 min)

**Why:** On Minikube, the repo-server clones the full Git repo on every sync cycle.
Large repos or many apps slow this down significantly.

**Fix:**
```bash
# 1. Enable git shallow clones
# In argocd-cm ConfigMap:
kubectl edit configmap argocd-cm -n argocd
# Add:
data:
  reposerver.git.fetch.period.seconds: "180"  # reduce poll frequency

# 2. Increase repo-server resources
kubectl edit deployment argocd-repo-server -n argocd
# Increase CPU limit from 200m to 500m

# 3. Use webhook instead of polling
# GitHub → Repo Settings → Webhooks → Add webhook
# URL: http://argocd.local/api/webhook
# Content-Type: application/json
# Events: push
```

---

### 12.2 Prometheus Using Too Much Memory

**Symptoms:**
```
kubectl top pods -n monitoring
NAME                                  CPU    MEMORY
prometheus-kube-prom-stack-xxx        500m   3Gi   ← too high
```

**Fix:**
```bash
# Reduce retention in kube-prometheus-values.yaml
prometheusSpec:
  retention: 3d         # was 7d
  retentionSize: "2GB"  # hard size limit

# Reduce scrape interval (30s is already reasonable, don't go lower)

# Drop high-cardinality metrics you don't need
prometheusSpec:
  scrapeConfigSelector: {}
  additionalScrapeConfigs:
    - job_name: sample-app
      metric_relabel_configs:
        - source_labels: [__name__]
          regex: 'go_.*'   # drop all Go runtime metrics if not needed
          action: drop

# Apply:
helm upgrade kube-prom-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --values monitoring/kube-prometheus-values.yaml
```

---

### 12.3 HPA Not Scaling (Metrics Not Available)

**Symptoms:**
```bash
kubectl describe hpa sample-app -n prod
# Conditions: AbleToScale: False
# Message: the HPA was unable to compute the replica count:
#          unable to get metrics for resource cpu: unable to fetch metrics
```

**Fix:**
```bash
# 1. Verify metrics-server is running
kubectl get deployment metrics-server -n kube-system

# 2. Check HPA can see metrics
kubectl top pods -n prod   # must work for HPA to work

# 3. If metrics-server not installed
minikube addons enable metrics-server --profile gitops-platform

# 4. Check resource requests are set (HPA needs requests to calculate %)
kubectl get deployment sample-app -n prod -o yaml | grep -A5 resources
# Must have: requests.cpu set — HPA calculates % of request, not limit
```

---

## 13. Real Issues We Hit in This Project

This section documents the exact errors encountered during the setup of this
platform, in the order they appeared, with the exact fix applied.

---

### Issue #1: `htpasswd: command not found`

**When:** Running `bootstrap/02-install-argocd.sh`

**Error:**
```
bootstrap/02-install-argocd.sh: line 18: htpasswd: command not found
```

**Root cause:** The script tried to bcrypt-hash the admin password using `htpasswd`,
which is not installed on Windows/Git Bash environments.

**Fix applied:** Skipped the password hash flag. ArgoCD auto-generates a password
and stores it in `argocd-initial-admin-secret`. Retrieved it with:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
# Result: lkS0xxlbND4GO6XK
```

**Lesson:** Don't rely on system tools (`htpasswd`, `openssl`) for password hashing
in bootstrap scripts. Use ArgoCD's built-in secret generation instead.

---

### Issue #2: Port 8080 Already in Use

**When:** Running `bootstrap/05-bootstrap-gitops.sh`

**Error:**
```
Unable to listen on port 8080: Listeners failed to create with the following errors:
[unable to create listener: Error listen tcp4 127.0.0.1:8080: bind: Only one usage...]
```

**Root cause:** `preview_start` had already started a `kubectl port-forward` for
ArgoCD on port 8080. The bootstrap script tried to start another one.

**Fix applied:** Bypassed the bootstrap script entirely and applied manifests directly:
```bash
kubectl apply -f argocd/projects/ -n argocd
kubectl apply -f argocd/app-of-apps.yaml
```

**Lesson:** When port-forwarding for local dev, always check what's already
forwarding before adding a new one. Use different local ports if needed.

---

### Issue #3: `argocd: command not found`

**When:** Running `bootstrap/05-bootstrap-gitops.sh`

**Error:**
```
bootstrap/05-bootstrap-gitops.sh: line 22: argocd: command not found
```

**Root cause:** ArgoCD CLI was not installed on the machine.

**Fix applied:** Applied all manifests directly via `kubectl apply` — no ArgoCD CLI needed:
```bash
kubectl apply -f argocd/projects/ -n argocd
kubectl apply -f argocd/app-of-apps.yaml
```

**Lesson:** Bootstrap scripts should check for required tools at the start and
print clear installation instructions if missing. Add a `check_prerequisites()`
function at the top of each script.

---

### Issue #4: `namespaces "argocd" not found` — Port-Forward Too Early

**When:** Attempting `preview_start` for ArgoCD UI immediately after Minikube confirmed "done"

**Error:**
```
Error from server (NotFound): namespaces "argocd" not found
```

**Root cause:** Minikube was running but only the monitoring stack had been installed.
ArgoCD (bootstrap step 02) hadn't been run yet.

**Fix applied:** Diagnosed the actual cluster state first:
```bash
kubectl get namespaces
kubectl get pods -A
```
Found that only `monitoring` and `ingress-nginx` namespaces existed.
Started Grafana/Prometheus/Alertmanager instead, and later ran ArgoCD install.

**Lesson:** Always verify cluster state before trying to connect to services.
The correct debugging sequence is: namespaces → pods → services → port-forward.

---

### Issue #5: Service Name Mismatch (`kube-prometheus-stack` vs `kube-prom-stack`)

**When:** Port-forwarding to Grafana

**Error:**
```
Error from server (NotFound): services "kube-prometheus-stack-grafana" not found
```

**Root cause:** The Helm release was installed as `kube-prom-stack` (shorter name),
not `kube-prometheus-stack` as assumed in the launch.json. All generated resource
names use the release name as prefix.

**Fix applied:**
```bash
kubectl get svc -n monitoring    # discover actual service names
# Found: kube-prom-stack-grafana

# Updated .claude/launch.json:
"runtimeArgs": ["port-forward", "svc/kube-prom-stack-grafana", ...]
```

**Lesson:** Never hardcode assumed Helm release names. Always run
`helm list -A` and `kubectl get svc -n <namespace>` to find actual names.

---

### Issue #6: `REPO_URL_PLACEHOLDER` Not Substituted in App-of-Apps

**When:** After applying `argocd/app-of-apps.yaml`

**Error:**
```
Message: Failed to load target state: ...
Sync.Compared.Source.RepoURL: REPO_URL_PLACEHOLDER
```

**Root cause:** `app-of-apps.yaml` contained literal placeholders (`REPO_URL_PLACEHOLDER`,
`BRANCH_PLACEHOLDER`). The bootstrap script was supposed to run `sed` to replace these
before applying, but the script wasn't used — we applied directly with `kubectl apply`.

**Fix applied:** Edited the file to replace placeholders with real values:
```yaml
repoURL: https://github.com/bonganiajay26/argocd-gitops.git
targetRevision: main
```
Then committed, pushed, and re-applied.

**Lesson:** Avoid placeholders in Kubernetes manifests that are applied directly.
Instead, use Kustomize variables, Helm values, or environment-specific files that
are complete and valid as-is — no substitution step required.

---

### Issue #7: App-of-Apps Synced But No Child Apps Created

**When:** After fixing the repo URL, root app showed Synced but no child apps appeared

**Diagnosis:**
```bash
kubectl get applications -n argocd
# NAME               SYNC STATUS   HEALTH STATUS
# root-app-of-apps   Synced        Healthy
# (no children)
```

**Root cause:** ArgoCD's directory source doesn't recurse into subdirectories by default.
Child apps were in `argocd/applications/dev/`, `argocd/applications/staging/`,
`argocd/applications/prod/` — one level deep — but ArgoCD only read the top-level
`argocd/applications/` directory.

**Fix applied:**
```yaml
# argocd/app-of-apps.yaml
spec:
  source:
    path: argocd/applications
    directory:
      recurse: true    ← added
```

**Lesson:** When using the App-of-Apps pattern with nested directories,
always set `directory.recurse: true`. Alternatively, keep all child app YAMLs
in a flat directory to avoid the issue entirely.

---

### Issue #8: GitHub Push Rejected (Remote Contains Unrelated History)

**When:** Running `git push -u origin main` for the first time

**Error:**
```
! [rejected]  main -> main (fetch first)
error: failed to push some refs to 'https://github.com/...'
hint: Updates were rejected because the remote contains work that you do not have locally.
```

**Root cause:** The GitHub repo was created with "Initialize repository with README"
checked, so it already had a commit. Our local repo had a completely different
initial commit — Git refused to push because histories diverged.

**Fix applied:**
```bash
git pull origin main --allow-unrelated-histories --no-edit
# Merge conflict in README.md → kept ours
git checkout --ours README.md
git add README.md
git commit -m "chore: resolve README merge"
git push -u origin main
```

**Lesson:** When pushing to a new GitHub repo for the first time, always create
it with "No template / empty repository" (no README, no .gitignore, no license).
This avoids the unrelated-histories merge entirely.

---

## Quick Diagnostic Commands

```bash
# === CLUSTER HEALTH ===
kubectl get nodes                          # node ready?
kubectl get pods -A | grep -v Running      # anything not Running?
kubectl top nodes                          # resource usage
kubectl get events -A --sort-by=.lastTimestamp | tail -30  # recent events

# === ARGOCD ===
kubectl get applications -n argocd         # app sync status
kubectl describe application <name> -n argocd | grep -A10 "Conditions\|Message"
kubectl logs -n argocd deployment/argocd-repo-server | tail -30

# === MONITORING ===
kubectl get pods -n monitoring             # all monitoring pods up?
kubectl get servicemonitor -A              # SMs exist?
kubectl get prometheusrule -A             # alert rules exist?

# === INGRESS ===
kubectl get ingress -A                    # ingress rules exist?
kubectl get svc -n ingress-nginx          # controller service?
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller | tail -20

# === SPECIFIC POD ===
kubectl describe pod <pod> -n <ns>        # events + status
kubectl logs <pod> -n <ns> --previous     # crashed container logs
kubectl exec -it <pod> -n <ns> -- sh      # shell into running pod
```
