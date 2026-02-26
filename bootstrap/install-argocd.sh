#!/bin/bash
set -euo pipefail

echo "🚀 Installing ArgoCD to k3s cluster..."

# Create namespace
echo "📦 Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
echo "📥 Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

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
echo "2. Port-forward to access UI:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "3. Access ArgoCD UI:"
echo "   https://localhost:8080"
echo "   Username: admin"
echo "   Password: (from step 1)"
echo ""
echo "4. Deploy ArgoCD Application (ArgoCD manages itself):"
echo "   kubectl apply -f ../argocd/applications/argocd.yaml"
echo ""
echo "5. Deploy Traefik:"
echo "   kubectl apply -f ../argocd/applications/traefik.yaml"
