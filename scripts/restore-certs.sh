#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backup/certificates}"

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
  echo "No backups found in $BACKUP_DIR — skipping restore"
  exit 0
fi

echo "Restoring TLS secrets from $BACKUP_DIR..."

for file in "$BACKUP_DIR"/*.json; do
  filename=$(basename "$file")
  ns=$(jq -r '.metadata.namespace' "$file")

  echo "  Restoring $ns/$filename"

  kubectl get namespace "$ns" &>/dev/null || kubectl create namespace "$ns"

  jq 'del(.metadata.annotations["cert-manager.io/alt-names"], .metadata.annotations["cert-manager.io/certificate-name"], .metadata.annotations["cert-manager.io/common-name"], .metadata.annotations["cert-manager.io/ip-sans"], .metadata.annotations["cert-manager.io/issuer-group"], .metadata.annotations["cert-manager.io/issuer-kind"], .metadata.annotations["cert-manager.io/issuer-name"], .metadata.annotations["cert-manager.io/uri-sans"], .metadata.ownerReferences)' "$file" \
    | kubectl apply -n "$ns" -f -
done

echo "✅ Restore complete"
echo ""
echo "cert-manager will detect existing valid secrets and skip ACME issuance."
