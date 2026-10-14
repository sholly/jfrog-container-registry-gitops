#!/usr/bin/env bash
#
# Post-deploy checks. Read-only -- safe to run repeatedly.
#
# Usage:  ./scripts/verify.sh [namespace]
set -uo pipefail

NS="${1:-jfrog-jcr}"
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
note() { printf '    %s\n' "$1"; }

echo "== ArgoCD Applications =="
for app in jfrog-jcr-bootstrap jfrog-jcr-platform jfrog-jcr-registry; do
  read -r sync health < <(oc -n openshift-gitops get application "$app" \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null)
  if [[ -z "${sync:-}" ]]; then
    bad "$app not found"
  elif [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    ok "$app  $sync/$health"
  else
    bad "$app  ${sync:-?}/${health:-?}"
  fi
done

echo "== Out-of-band Secrets =="
for s in jfrog-jcr-keys jfrog-jcr-postgresql; do
  if oc -n "$NS" get secret "$s" >/dev/null 2>&1; then
    ok "secret/$s present"
  else
    bad "secret/$s MISSING -- run scripts/create-secrets.sh"
  fi
done

echo "== SCC binding (built-in nonroot-v2) =="
for sa in jfrog-jcr jfrog-jcr-postgresql; do
  if oc auth can-i use scc/nonroot-v2 \
       --as="system:serviceaccount:${NS}:${sa}" >/dev/null 2>&1; then
    ok "sa/$sa can use scc/nonroot-v2"
  else
    bad "sa/$sa CANNOT use scc/nonroot-v2 -- check the RoleBinding"
  fi
done
# Nothing should have been admitted under restricted-v2 or anyuid.
if oc -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}' 2>/dev/null \
     | grep -qv '^nonroot-v2$\|^$'; then
  bad "some pods were admitted under an SCC other than nonroot-v2"
else
  ok "no pod admitted under an unexpected SCC"
fi

echo "== Workloads =="
oc -n "$NS" get statefulset,deployment 2>/dev/null | sed 's/^/  /'
# Confirm the SCC that was actually admitted, which is the real proof.
echo "== Admitted SCC per pod =="
oc -n "$NS" get pods \
  -o custom-columns='POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc,STATUS:.status.phase' \
  2>/dev/null | sed 's/^/  /'

echo "== Route =="
host="$(oc -n "$NS" get route jfrog-jcr -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -n "$host" ]]; then
  ok "route -> https://$host"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/router/api/v1/system/health" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    ok "router health returns 200"
  else
    bad "router health returned ${code:-no response}"
  fi
  # The Docker v2 endpoint must answer 401 with a Bearer challenge; a 404 here
  # means the repository-path method is not being served.
  challenge="$(curl -s -D- -o /dev/null --max-time 15 "https://${host}/v2/" 2>/dev/null | tr -d '\r' | grep -i '^www-authenticate:')"
  if [[ -n "$challenge" ]]; then
    ok "docker /v2/ returns an auth challenge"
    note "$challenge"
  else
    bad "docker /v2/ did not return a WWW-Authenticate challenge"
  fi
else
  bad "route/jfrog-jcr not found"
fi

echo
[[ $fail -eq 0 ]] && echo "All checks passed." || echo "Some checks failed (see ✗ above)."
exit $fail
