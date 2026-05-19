#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../terraform"

echo "=== Destroying all resources ==="
terraform destroy -auto-approve

echo "=== Cleanup: removing resource group if left behind ==="
az group delete --name rg-sandbox-aks --yes --no-wait 2>/dev/null || true
