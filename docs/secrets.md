# Secrets

Two Secrets are required and are deliberately **not** in Git.

| Secret | Keys | Consumed by |
|---|---|---|
| `jfrog-jcr-keys` | `master-key`, `join-key` | Artifactory, frontend, jfbus |
| `jfrog-jcr-postgresql` | `postgres-password`, `password` | PostgreSQL, Artifactory |

Wired in `values-common.yaml` via `global.masterKeySecretName`,
`global.joinKeySecretName` and `postgresql.auth.existingSecret`.

## Why the master key cannot be chart-generated

The chart will happily generate a master key if you do not supply one. Under
Helm that is survivable, because Helm can read the previous release's value.
Under ArgoCD it is not: ArgoCD renders manifests with `helm template`, which
has no cluster state and no previous release. Every single sync would mint a
**new** master key.

The master key encrypts everything sensitive in the Artifactory database —
stored credentials for remote repositories, LDAP bind passwords, access tokens,
signing keys. Change it and that data becomes permanently unreadable, while
Artifactory keeps starting up and reporting healthy. It is a quiet, total loss.

Pinning both keys to a pre-existing Secret is what makes this chart safe to run
under GitOps at all. The rendered output confirms the keys are referenced rather
than embedded:

```yaml
- name: JF_SHARED_SECURITY_MASTERKEY
  valueFrom:
    secretKeyRef:
      name: jfrog-jcr-keys
      key: master-key
```

`jcr-artifactory-unified-secret`, which ArgoCD *does* manage, contains only
`system.yaml`, `binarystore.xml` and an access config patch — no keys.

## Getting started: the script

```bash
./scripts/create-secrets.sh [namespace]
```

Generates both Secrets with `openssl rand`. It refuses to overwrite an existing
`jfrog-jcr-keys`, for the reason above.

This is fine for bootstrapping and wrong as a long-term answer: the values exist
only in the cluster, nobody can recreate them, and a namespace rebuild loses the
registry. Move to one of the following.

## External Secrets Operator (recommended)

Keeps the real values in Vault / AWS Secrets Manager / Azure Key Vault and lets
a Git-managed `ExternalSecret` project them into the namespace. Add the
`ExternalSecret` to `platform/` and it syncs with everything else.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jfrog-jcr-keys
  namespace: jfrog-jcr
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: jfrog-jcr-keys
    creationPolicy: Owner
  data:
    - secretKey: master-key
      remoteRef:
        key: jfrog/jcr
        property: master_key
    - secretKey: join-key
      remoteRef:
        key: jfrog/jcr
        property: join_key
```

Set `refreshInterval` with care. If the upstream value ever changes, ESO will
propagate it, and for the master key that is destructive. Pin it in the backing
store and treat it as write-once.

## Sealed Secrets

If there is no external secret manager, Sealed Secrets lets the encrypted form
live safely in Git:

```bash
oc -n jfrog-jcr create secret generic jfrog-jcr-keys \
  --from-literal=master-key="$(openssl rand -hex 32)" \
  --from-literal=join-key="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > platform/sealedsecret-keys.yaml
```

Add it to `platform/kustomization.yaml`. Back up the controller's sealing key —
lose it and the SealedSecrets in Git are undecryptable.

## Rotation

- **`join-key`** — safe to rotate. Restart the Artifactory pods afterwards.
- **`postgres-password` / `password`** — rotate in PostgreSQL first
  (`ALTER USER`), then update the Secret, then restart Artifactory.
- **`master-key`** — do **not** rotate in place. It requires JFrog's documented
  key-rotation procedure while Artifactory is running; editing the Secret
  bricks the instance.
