#!/usr/bin/env bash
#
# Creates the two Secrets that are deliberately NOT in Git:
#
#   jfrog-jcr-keys        master-key, join-key
#   jfrog-jcr-postgresql  postgres-password, password
#
# Run this ONCE, before the registry Application first syncs. It is
# idempotent: if a Secret already exists it is left untouched, because
# rotating the master key makes every credential already encrypted in the
# Artifactory database unreadable.
#
# Usage:  ./scripts/create-secrets.sh [namespace]
set -euo pipefail

NS="${1:-jfrog-jcr}"

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found in PATH" >&2; exit 1; }

oc get namespace "$NS" >/dev/null 2>&1 || {
  echo "Namespace $NS does not exist yet."
  echo "Sync the jfrog-jcr-platform Application first, or: oc create namespace $NS"
  exit 1
}

# --- cluster keys ----------------------------------------------------------
if oc -n "$NS" get secret jfrog-jcr-keys >/dev/null 2>&1; then
  echo "secret/jfrog-jcr-keys already exists -- leaving it alone."
  echo "  (Regenerating the master key would orphan all encrypted config."
  echo "   Delete it by hand only if this is a fresh install with no data.)"
else
  # master-key must be 32 bytes hex-encoded; join-key is a 32-char hex token.
  oc -n "$NS" create secret generic jfrog-jcr-keys \
    --from-literal=master-key="$(openssl rand -hex 32)" \
    --from-literal=join-key="$(openssl rand -hex 16)"
  echo "created secret/jfrog-jcr-keys"
fi

# --- postgresql credentials ------------------------------------------------
if oc -n "$NS" get secret jfrog-jcr-postgresql >/dev/null 2>&1; then
  echo "secret/jfrog-jcr-postgresql already exists -- leaving it alone."
else
  # Key names match postgresql.auth.secretKeys in values-common.yaml.
  #   postgres-password -> the 'postgres' superuser
  #   password          -> the 'artifactory' application user
  oc -n "$NS" create secret generic jfrog-jcr-postgresql \
    --from-literal=postgres-password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)" \
    --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  echo "created secret/jfrog-jcr-postgresql"
fi

# Label them so they are visibly out-of-band rather than looking like drift.
oc -n "$NS" label secret jfrog-jcr-keys jfrog-jcr-postgresql \
  app.kubernetes.io/part-of=jfrog-container-registry \
  app.kubernetes.io/managed-by=out-of-band --overwrite >/dev/null

echo
echo "Done. Both Secrets are unmanaged by ArgoCD on purpose."
echo "For a long-term answer, replace this script with External Secrets"
echo "Operator or Sealed Secrets -- see docs/secrets.md."
