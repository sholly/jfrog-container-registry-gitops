# JFrog Container Registry (OSS) on OpenShift via OpenShift GitOps

Declarative deployment of [JFrog Container Registry](https://jfrog.com/container-registry/)
(JCR — the free, OSS edition of Artifactory) to OpenShift, managed end-to-end
by OpenShift GitOps (ArgoCD).

Validated against **OpenShift 4.22**, **OpenShift GitOps 1.22.1**, chart
**`jfrog/artifactory-jcr` 107.161.26** (app 7.161.26).

---

## Layout

```
bootstrap/root-application.yaml   The only thing you apply by hand (app-of-apps)
gitops/                           AppProject + the two child Applications
  appproject.yaml
  application-platform.yaml       -> syncs platform/
  application-registry.yaml       -> syncs the JFrog Helm chart
platform/                         Namespace, SAs, SCC binding, Route, NetworkPolicies
registry/values/                  Helm values (common + per-cluster overlay)
scripts/                          set-repo-url.sh, create-secrets.sh, verify.sh
docs/                             storage.md, secrets.md, operations.md
```

## The three Applications

| Application | Source | Wave | Creates |
|---|---|---|---|
| `jfrog-jcr-bootstrap` | git `gitops/` | — | the AppProject and the two apps below |
| `jfrog-jcr-platform` | git `platform/` (kustomize) | `-10` | Namespace, ServiceAccounts, SCC RoleBinding, Route, NetworkPolicies |
| `jfrog-jcr-registry` | `charts.jfrog.io` + git values | `0` | Artifactory, frontend, jfbus, PostgreSQL |

The platform Application **must** converge first. If the Helm chart syncs
before the SCC RoleBinding exists, the first Artifactory pod is admitted under
`restricted-v2` and rejected for its UID. Sync waves enforce the ordering.

`jfrog-jcr-registry` is a **multi-source** Application: the chart is pulled
straight from JFrog's public Helm repo and the values files are read from this
Git repo via the `$values` ref. Nothing is vendored, so a version bump is a
one-line change to `targetRevision`.

---

## Install

### 1. Set your Git repo URL

Already done for this repo — all four ArgoCD manifests point at
`https://github.com/sholly/jfrog-container-registry-gitops.git`, branch `main`.

If the URL or branch ever changes:

```bash
./scripts/set-repo-url.sh <git-url> [branch]
```

Commit and push before bootstrapping. ArgoCD reads from Git, not from your working copy, so
unpushed changes are invisible to it.

### 2. Review the cluster overlay

`registry/values/values-ocprod.yaml` is written for `apps.ocprod.303.tube`
with the `nfs-client` StorageClass. For another cluster, copy it, adjust the
storage class / sizes / Route host, and point
`application-registry.yaml` at the new file.

Also update `spec.host` in `platform/route.yaml` to match your ingress domain.

### 3. Create the two Secrets

These are deliberately **not** in Git:

```bash
oc create namespace jfrog-jcr      # or let the platform Application do it
./scripts/create-secrets.sh
```

This creates `jfrog-jcr-keys` (master-key, join-key) and
`jfrog-jcr-postgresql` (postgres-password, password). The script is idempotent
and will never overwrite existing values — see [docs/secrets.md](docs/secrets.md)
for why that matters and how to move to External Secrets or Sealed Secrets.

### 4. Bootstrap

```bash
oc apply -f bootstrap/root-application.yaml
```

Everything else follows from Git.

### 5. Verify

```bash
./scripts/verify.sh
```

Checks Application health, Secret presence, that the SCC binding works, which
SCC each pod was *actually* admitted under, and that the Docker `/v2/` endpoint
returns an auth challenge.

First start takes several minutes: Artifactory runs a schema migration against
an empty database before it reports ready.

---

## Two decisions worth knowing about

### Security context: the built-in `nonroot-v2` SCC, not a custom one

The JFrog images run as fixed numeric users — artifactory `1030`, frontend
`1031`, jfbus `1127`, postgres `1001` — and the chart sets `runAsUser`/`fsGroup`
to match. OpenShift's default `restricted-v2` SCC uses
`runAsUser: MustRunAsRange` and rejects all of them, since they sit outside the
range allocated to the namespace. Verified on-cluster:

```
$ oc adm policy scc-subject-review -f pod-uid-1030.yaml \
    -u system:serviceaccount:default:default
RESOURCE        ALLOWED BY
Pod/scc-probe   <none>          # rejected
```

The common fixes are to grant `anyuid` or to hand-roll an SCC with
`runAsUser: RunAsAny`. Both permit UID 0. Nothing here needs root — every
container *and* init container in the rendered chart already runs non-root with
`ALL` capabilities dropped, `allowPrivilegeEscalation: false` and
`RuntimeDefault` seccomp.

So this repo binds the **built-in `nonroot-v2`** SCC instead. It relaxes exactly
the two checks that block the deployment (`runAsUser` → `MustRunAsNonRoot`,
`fsGroup` → `RunAsAny`) and keeps everything else `restricted-v2` enforces.
Confirmed to admit all four UIDs:

```
uid=1001  nonroot-v2
uid=1030  nonroot-v2
uid=1031  nonroot-v2
uid=1127  nonroot-v2
```

The result is stricter than the usual approach, and this repo defines no
cluster-scoped security object at all — the `AppProject` needs no permission
over `SecurityContextConstraints` or `ClusterRoles`.

One non-obvious requirement: the chart renders `frontend` and `jfbus` as their
own Deployments (`frontend.asPod` defaults to true), and those templates only
set `serviceAccountName` **if you supply one**. Left unset, they land on the
namespace `default` ServiceAccount, which is not bound to `nonroot-v2`, and
fail admission. `values-common.yaml` pins both to `jfrog-jcr`.

### Docker access: Route to the Artifactory router, repository-path method

nginx is disabled. The chart's nginx exists mainly to serve the Docker
*subdomain* method — it extracts the repo from a hostname
(`server_name ~(?<repo>.+)\.<fullname>`) and rewrites `/v2/...` to
`/artifactory/api/docker/<repo>/v2/...`. On OpenShift that needs wildcard DNS
*and* `routeAdmission.wildcardPolicy: WildcardsAllowed` on the ingress
controller, which is off by default.

Instead, a single edge-terminated Route targets the Artifactory router on
`8082`, which serves the UI and the Docker endpoints natively using the
**repository-path** method:

```bash
podman login jcr.apps.ocprod.303.tube
podman pull  jcr.apps.ocprod.303.tube/docker-local/nginx:latest
```

The Route carries `haproxy.router.openshift.io/timeout: 600s` — the router's
30s default aborts large layer transfers mid-push.

To use the subdomain method instead, re-enable `nginx` in
`values-common.yaml`, add a `wildcardPolicy: Subdomain` Route, and enable
wildcard routes on the ingress controller.

---

## Before calling this production

- **PostgreSQL is on NFS.** `nfs-client` is the only StorageClass on this
  cluster. Artifactory's filestore on NFS is fine and common; a PostgreSQL data
  directory on NFS is the real risk. Read [docs/storage.md](docs/storage.md) —
  this is the one item to resolve, not a footnote.
- **Secrets are created out-of-band** by a script. Replace with External
  Secrets Operator or Sealed Secrets: [docs/secrets.md](docs/secrets.md).
- **Backups.** Nothing here backs up the filestore or the database.
- **TLS** is the default ingress wildcard certificate. Supply a real one for a
  trusted registry endpoint, or container runtimes will need
  `insecure-registries` entries.
- **Tighten PSA.** The namespace enforces `baseline` and audits `restricted`.
  Check for warnings after the first deploy, then raise `enforce` to
  `restricted` if clean.

See [docs/operations.md](docs/operations.md) for upgrades, scaling and
day-2 tasks.

## Validation performed

The manifests in this repo were validated against the live cluster without
being deployed:

- `helm template` renders cleanly; all 14 objects pass `oc apply --dry-run=server`
- `oc kustomize platform|gitops` build; all objects pass server-side dry-run
- all four pod shapes confirmed admitted by `nonroot-v2` via `scc-subject-review`
- confirmed no container or init container requests root
- `shellcheck` clean

Not verified, because it needs a real deployment: pod startup, the NFS
PostgreSQL behaviour discussed in `docs/storage.md`, and an end-to-end
`docker push`. `scripts/verify.sh` covers all three after you deploy.
