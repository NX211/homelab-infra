#!/bin/bash
set -euo pipefail

echo "🚀 Installing ArgoCD to k3s cluster..."

# Create namespace
echo "📦 Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD (using server-side apply to handle large CRDs)
echo "📥 Installing ArgoCD..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "⏳ Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd

echo "✅ ArgoCD installed successfully!"
echo ""
echo "📝 Next steps:"
echo "1. Get initial admin password:"
echo "   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "2. Port-forward to access UI (TEMPORARY - only until Traefik is deployed):"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
echo ""
echo "3. Configure ArgoCD and deploy infrastructure:"
echo "   Follow ../BOOTSTRAP.md for complete deployment steps"
echo ""
echo "4. After Traefik + IngressRoute are deployed, access ArgoCD at:"
echo "   https://cd.authoritah.com"
echo "   (No more port-forwarding needed!)"
