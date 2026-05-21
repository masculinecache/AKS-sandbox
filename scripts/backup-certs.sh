#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backup/certificates}"
mkdir -p "$BACKUP_DIR"

echo "Backing up TLS secrets to $BACKUP_DIR..."

for ns in echo-server-nginx echo-server-cilium; do
  for secret in $(kubectl get secret -n "$ns" --field-selector type=kubernetes.io/tls -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    echo "  Backing up $ns/$secret"
    kubectl get secret -n "$ns" "$secret" -o json \
      | jq 'del(.metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.selfLink, .metadata.ownerReferences, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
      > "$BACKUP_DIR/${ns}-${secret}.json"
  done
done

echo "✅ Backup complete"
ls -la "$BACKUP_DIR/"
