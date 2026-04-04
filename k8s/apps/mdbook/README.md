# mdbook Kubernetes Deployment

This directory contains the Kubernetes manifests for deploying the Cardano Operations Book (mdbook) to the EKS cluster.

## Architecture

- **Production**: [book-k8s.play.dev.cardano.org](https://book-k8s.play.dev.cardano.org)
  - 2 replicas with pod anti-affinity (different nodes)
  - Always running

- **Staging**: [book-staging-k8s.play.dev.cardano.org](https://book-staging-k8s.play.dev.cardano.org)
  - **Default: 0 replicas (scaled down)**
  - Runs on spot instances when scaled up
  - Includes robots.txt and noindex meta tags to prevent search engine indexing

## Infrastructure

- **Shared ALB**: Both production and staging use the same Application Load Balancer (cost optimization)
- **Automatic TLS**: Certificates managed by cert-manager with Let's Encrypt
- **Automatic DNS**: DNS records managed by external-dns
- **HTTP → HTTPS**: Automatic redirect

## Image Building

Images are built using Nix and include:
- Go static file server
- mdbook content generated at build time

## Publishing New Content

### 1. Update mdbook content and version

Edit files in the `mdbook/` directory as needed.

Increment version in `perSystem/packages/images/mdbook.nix` (e.g., `v1.0.0` → `v1.0.1`)

### 2. Test on Staging

Build, push, and update staging deployment tags:
```bash
just release-image mdbook-staging

# Disable ArgoCD auto-sync
kubectl -n argocd patch application mdbook --type json -p='[{"op": "remove", "path": "/spec/syncPolicy/automated"}]'

# Scale up staging
# Edit k8s/overlays/playground/mdbook/kustomization.yaml and change staging replicas from 0 to 1

# Deploy manually
kustomize build k8s/overlays/playground/mdbook | kubectl apply -f -

# Wait ~60-90 seconds for ALB target registration
# Then access: https://book-staging-k8s.play.dev.cardano.org
```

### 3. Validate and Release

Once staging is approved:
```bash
# Scale staging back down
# Edit k8s/overlays/playground/mdbook/kustomization.yaml and change staging replicas back to 0

# Build and push production image
just release-image mdbook-production

# Commit all changes
git add/commit/push.
# usually use commit message like: "book: deploy for <reason>"

# Re-enable ArgoCD auto-sync
kubectl apply -f k8s/overlays/playground/application.mdbook.yaml
```
