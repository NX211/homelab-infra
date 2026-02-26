#!/bin/bash
set -euo pipefail

echo "🔐 Installing External Secrets Operator..."

# Add Helm repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install ESO
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --values values.yaml \
  --wait

echo "✅ External Secrets Operator installed!"
echo ""
echo "📝 Next steps:"
echo "1. Get your Bitwarden Access Token from: https://vault.bitwarden.com/#/settings/security/security-keys"
echo "2. Create the Bitwarden credentials secret:"
echo "   kubectl create secret generic bitwarden-credentials \\"
echo "     --from-literal=token='YOUR_BITWARDEN_ACCESS_TOKEN' \\"
echo "     -n external-secrets-system"
echo ""
echo "3. Create the ClusterSecretStore:"
echo "   kubectl apply -f clustersecretstore.yaml"
echo ""
echo "4. Test with an ExternalSecret:"
echo "   kubectl apply -f examples/test-externalsecret.yaml"
