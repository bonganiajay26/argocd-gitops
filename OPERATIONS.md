# Operations Guide — GitOps Platform

## Deployment Workflow (End-to-End)

```
CODE CHANGE FLOW:
─────────────────────────────────────────────────────────────────────────────

  1. Developer pushes code
     └─► GitHub Actions CI runs:
           • docker build & push → ghcr.io/org/sample-app:abc1234
           • kustomize edit set image (dev overlay)
           • git commit + push

  2. Git repo updated
     └─► apps/sample-app/overlays/dev/kustomization.yaml
           newTag: "abc1234"    ← changed

  3. ArgoCD detects diff (polls every 3 min)
     └─► argocd-repo-server clones repo
     └─► kustomize build overlays/dev
     └─► diff against live cluster state

  4. ArgoCD auto-syncs (dev only)
     └─► kubectl apply rendered manifests to dev namespace
     └─► Deployment rolling update begins

  5. Kubernetes reconciles
     └─► New pod scheduled → pulls image → starts
     └─► Readiness probe passes → old pod terminated
     └─► Zero-downtime complete

  6. Developer promotes to staging (manual trigger)
     └─► GitHub Actions promote.yaml workflow
     └─► Updates staging overlay tag
     └─► Direct push → ArgoCD auto-syncs staging

  7. SRE promotes to prod (PR-based gate)
     └─► promote.yaml opens PR → team reviews
     └─► PR merged → ArgoCD detects diff
     └─► Prod has NO auto-sync → shows OutOfSync
     └─► SRE manually syncs in ArgoCD UI or:
           argocd app sync sample-app-prod
```

---

## Day-2 Operations

### Check sync status of all apps
```bash
argocd app list
# NAME                  CLUSTER   NAMESPACE  PROJECT  STATUS     HEALTH
# root-app-of-apps      in-cluster argocd    default  Synced     Healthy
# sample-app-dev        in-cluster dev       dev      Synced     Healthy
# sample-app-staging    in-cluster staging   staging  Synced     Healthy
# sample-app-prod       in-cluster prod      prod     OutOfSync  Healthy
```

### Manually sync prod
```bash
argocd app sync sample-app-prod --prune
```

### Rollback prod to previous version
```bash
# View history
argocd app history sample-app-prod

# Roll back to a specific revision
argocd app rollback sample-app-prod <REVISION-ID>

# Or: revert the Git commit (preferred — keeps Git as truth)
git revert HEAD~1 --no-edit
git push
# ArgoCD detects revert commit → sync restores old manifests
```

### Force hard refresh (clear cache)
```bash
argocd app get sample-app-dev --hard-refresh
```

### Get app diff before syncing
```bash
argocd app diff sample-app-prod
```

---

## Troubleshooting

### Minikube Issues

#### Cluster won't start
```bash
minikube delete --profile gitops-platform
minikube start --profile gitops-platform --driver=docker ...
# If docker driver fails, try --driver=virtualbox or --driver=hyperkit (macOS)
```

#### Out of disk space
```bash
minikube ssh --profile gitops-platform -- df -h
# Clear unused images inside Minikube VM
minikube ssh --profile gitops-platform -- docker system prune -f
```

#### Metrics-server not working
```bash
kubectl top nodes   # should show CPU/memory
# If error: metrics not available
minikube addons enable metrics-server --profile gitops-platform
kubectl rollout restart deployment/metrics-server -n kube-system
```

#### Minikube IP changed after restart
```bash
MINIKUBE_IP=$(minikube ip --profile gitops-platform)
# Update /etc/hosts
sudo sed -i "s/^[0-9.]* argocd.local.*/${MINIKUBE_IP}  argocd.local grafana.local app.dev.local app.staging.local app.prod.local/" /etc/hosts
```

---

### ArgoCD Sync Failures

#### App stuck in "Progressing"
```bash
# Check events
argocd app get sample-app-dev
kubectl describe application sample-app-dev -n argocd

# Check pod events in target namespace
kubectl get events -n dev --sort-by=.lastTimestamp | tail -20
```

#### "ComparisonError: failed to load target state"
```bash
# Repo server can't clone the repo
kubectl logs -n argocd deployment/argocd-repo-server

# Verify repo registration
argocd repo list

# Re-register repo
argocd repo add https://github.com/bonganiajay26/argocd-gitops.git --username git ...
```

#### "SyncFailed: one or more objects failed to apply"
```bash
# See what specific resource failed
argocd app get sample-app-dev --show-operation

# Render manifests locally to debug
cd apps/sample-app/overlays/dev
kustomize build . | kubectl apply --dry-run=client -f -
```

#### App auto-sync keeps firing (sync loop)
```bash
# Something in-cluster keeps mutating the resource (e.g., admission webhook)
# Add an ignoreDifferences entry in the Application spec:
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/metadata/annotations/injected-field
```

#### ArgoCD password reset
```bash
# Get initial admin password (set during install)
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Change password via CLI
argocd account update-password \
  --current-password <current> \
  --new-password <new>
```

---

### Monitoring Misconfigurations

#### Prometheus can't find ServiceMonitor targets
```bash
# Check Prometheus targets in UI: http://prometheus.local/targets
# Or port-forward:
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090

# Verify ServiceMonitor selector matches Prometheus config
kubectl get prometheus -n monitoring -o yaml | grep serviceMonitorSelector

# Verify ServiceMonitor label matches:
kubectl get servicemonitor -n dev sample-app -o yaml | grep labels -A5
# Must have: release: kube-prometheus-stack
```

#### Grafana shows "No data"
```bash
# 1. Verify datasource is configured
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o yaml

# 2. Port-forward and check datasource
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Go to: http://localhost:3000/datasources → Test connection

# 3. Check Prometheus is scraping the target
# In Prometheus UI: Status → Targets → filter by job="sample-app"
```

#### Alertmanager not sending alerts
```bash
# Check Alertmanager config is valid
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -- amtool config show

# Fire a test alert
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -- amtool alert add alertname=TestAlert severity=warning

# Check Alertmanager logs
kubectl logs -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0
```

---

### Common Pod Issues

#### Pod stuck in Pending
```bash
kubectl describe pod <pod> -n <ns>
# Look for:
#   Insufficient cpu / memory → increase Minikube resources or lower pod requests
#   No nodes available → single node cluster, all resources consumed
#   PVC not bound → check PV provisioner

# Quick fix: restart Minikube with more resources
minikube stop --profile gitops-platform
minikube start --profile gitops-platform --cpus=6 --memory=10240
```

#### CrashLoopBackOff
```bash
kubectl logs <pod> -n <ns> --previous   # logs from crashed container
kubectl describe pod <pod> -n <ns>       # check exit code, OOM events
```

#### ImagePullBackOff
```bash
kubectl describe pod <pod> -n <ns>
# If: "unauthorized: authentication required"
#   → Create imagePullSecret and reference in serviceAccount or pod spec
# If: "image not found"
#   → Check image tag in kustomization.yaml overlays
```

---

## Performance Tuning for Minikube

```bash
# Allocate more resources (requires cluster restart)
minikube stop --profile gitops-platform
minikube start --profile gitops-platform --cpus=6 --memory=10240 --disk-size=50g

# Enable swap (for memory-heavy workloads — dev only)
minikube ssh -- sudo sysctl vm.swappiness=10

# Preload images to avoid slow pulls
minikube image load gcr.io/google-samples/hello-app:1.0 --profile gitops-platform
```

---

## Useful Command Reference

```bash
# ArgoCD
argocd app list                                    # list all apps
argocd app get <name>                              # app details + health
argocd app diff <name>                             # what would change
argocd app sync <name>                             # trigger sync
argocd app sync <name> --revision <git-sha>        # sync to specific commit
argocd app rollback <name> <revision>              # rollback
argocd app history <name>                          # deployment history
argocd app set <name> --sync-policy automated      # enable auto-sync
argocd app set <name> --sync-policy none           # disable auto-sync

# Kubernetes
kubectl get all -n dev                             # everything in dev
kubectl get events -n prod --sort-by=.lastTimestamp # recent events
kubectl top pods -n prod                           # CPU/memory live
kubectl rollout history deployment/sample-app -n prod
kubectl rollout undo deployment/sample-app -n prod # rollback one version

# Helm
helm list -A                                       # all releases
helm history kube-prometheus-stack -n monitoring   # upgrade history
helm rollback kube-prometheus-stack 1 -n monitoring # rollback monitoring
```
