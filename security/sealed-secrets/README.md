# Sealed Secrets — How to Use

## Why

Plain Kubernetes Secrets are base64-encoded — not encrypted. Committing them
to Git exposes credentials. Sealed Secrets encrypts secrets with the cluster's
public key so only that cluster can decrypt them. Safe to commit to Git.

## Install Sealed Secrets Controller

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller
```

## Install kubeseal CLI

```bash
brew install kubeseal
```

## Workflow: Create a Sealed Secret

```bash
# 1. Create a regular secret (do NOT commit this file)
kubectl create secret generic my-app-secret \
  --from-literal=DB_PASSWORD='super-secret' \
  --dry-run=client \
  -o yaml > /tmp/my-secret.yaml

# 2. Seal it with the cluster's public key
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format yaml \
  < /tmp/my-secret.yaml \
  > security/sealed-secrets/my-app-secret-sealed.yaml

# 3. Commit the sealed secret — safe to push to Git
git add security/sealed-secrets/my-app-secret-sealed.yaml
git commit -m "feat: add sealed DB secret"

# 4. ArgoCD applies the SealedSecret; controller decrypts → creates Secret
kubectl get secret my-app-secret -n dev
```

## Example SealedSecret manifest (after sealing)

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: my-app-secret
  namespace: dev
spec:
  encryptedData:
    DB_PASSWORD: AgBy3...   # encrypted, safe to commit
  template:
    metadata:
      name: my-app-secret
      namespace: dev
```

## Key Rotation

```bash
# Force controller to generate a new sealing key
kubectl -n kube-system delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key

# Re-seal all secrets with new key
kubeseal --re-encrypt < old-sealed.yaml > new-sealed.yaml
```
