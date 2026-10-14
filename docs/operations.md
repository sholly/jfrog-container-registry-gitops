# Operations

## First login

```bash
oc -n jfrog-jcr get route jfrog-jcr -o jsonpath='{.spec.host}{"\n"}'
```

Open `https://<host>`. Default credentials are `admin` / `password`; Artifactory
forces a change on first login. Do that before exposing the Route more widely.

First start takes several minutes while Artifactory migrates a fresh schema.
Follow it with:

```bash
oc -n jfrog-jcr logs -f sts/jcr-artifactory -c artifactory
```

## Creating a Docker repository

In the UI: **Administration → Repositories → Create → Local → Docker**. Name it
`docker-local`.

Then, using the repository-path method:

```bash
podman login <host>
podman tag  myimage:latest <host>/docker-local/myimage:latest
podman push <host>/docker-local/myimage:latest
```

The ingress wildcard certificate is not trusted by default. Either install the
cluster CA on clients, or for a non-production trial:

```bash
# /etc/containers/registries.conf.d/jcr.conf
[[registry]]
location = "<host>"
insecure = true
```

## Letting OpenShift pull from the registry

```bash
oc -n <app-namespace> create secret docker-registry jcr-pull \
  --docker-server=<host> \
  --docker-username=<user> \
  --docker-password=<token>
oc -n <app-namespace> secrets link default jcr-pull --for=pull
```

Use an Artifactory access token, not the admin password.

## Upgrading the chart

Edit one line in `gitops/application-registry.yaml`:

```yaml
    - repoURL: https://charts.jfrog.io
      chart: artifactory-jcr
      targetRevision: 107.161.26   # <- bump
```

Before committing, diff the rendered output:

```bash
helm repo add jfrog https://charts.jfrog.io && helm repo update jfrog
for v in 107.161.26 <new>; do
  helm template jcr jfrog/artifactory-jcr --version "$v" -n jfrog-jcr \
    -f registry/values/values-common.yaml \
    -f registry/values/values-ocprod.yaml > "/tmp/jcr-$v.yaml"
done
diff -u /tmp/jcr-107.161.26.yaml /tmp/jcr-<new>.yaml
```

Watch for two things specifically:

- **New UIDs.** A new microservice with a fixed UID is fine (`nonroot-v2`
  allows any non-root UID) *unless* it also runs as root, which would fail
  admission. Check with
  `grep -E 'runAsUser: 0|privileged: true' /tmp/jcr-<new>.yaml`.
- **New split-out Deployments.** Any new component rendered as its own
  Deployment needs `serviceAccountName: jfrog-jcr` added to
  `values-common.yaml`, or it lands on the `default` ServiceAccount and fails
  admission. Confirm every pod template is covered:
  `grep -c 'serviceAccountName:' /tmp/jcr-<new>.yaml` should equal the number
  of Deployments plus StatefulSets.

Artifactory does not support downgrades once a schema migration has run. Take a
database backup before a major bump.

## Scaling

JCR does not support HA — `artifactory.replicaCount` must stay `1`. More than
one replica against the same filestore and database is unsupported and will
corrupt state. Scale vertically instead, in `values-common.yaml`:

```yaml
    resources:
      limits:
        memory: "12Gi"
    javaOpts:
      xmx: "10g"
```

Keep `resources.limits.memory` at least 1Gi above `javaOpts.xmx`. The JVM needs
headroom for metaspace, thread stacks and direct byte buffers, and it is the
container that gets OOM-killed, not the heap.

## Backups

Neither the chart nor this repo backs anything up. At minimum:

```bash
# Database
oc -n jfrog-jcr exec sts/jcr-postgresql -- \
  pg_dump -U artifactory artifactory | gzip > jcr-db-$(date +%F).sql.gz

# Filestore
oc -n jfrog-jcr exec sts/jcr-artifactory -c artifactory -- \
  tar cf - /var/opt/jfrog/artifactory/data/filestore | gzip > jcr-fs-$(date +%F).tar.gz
```

The database is the irreplaceable half — see
[storage.md](storage.md#postgresql-on-nfs-the-real-risk).

## Suspending ArgoCD for manual intervention

`selfHeal` reverts hand edits within seconds. To work by hand, disable it
rather than fighting it:

```bash
oc -n openshift-gitops patch application jfrog-jcr-registry --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Re-enable by re-syncing the bootstrap Application, which restores the Git
state.

## Troubleshooting

**Pods Pending, `FailedCreate` with `unable to validate against any security context constraint`**

The SCC RoleBinding is missing or the pod is on the wrong ServiceAccount:

```bash
oc -n jfrog-jcr get rolebinding jfrog-jcr-scc-nonroot
oc -n jfrog-jcr get pods -o custom-columns=\
'POD:.metadata.name,SA:.spec.serviceAccountName,SCC:.metadata.annotations.openshift\.io/scc'
```

Every pod should show a `jfrog-jcr*` ServiceAccount and `nonroot-v2`.

**Artifactory cannot reach the database**

```bash
oc -n jfrog-jcr get secret jfrog-jcr-postgresql -o jsonpath='{.data}' | tr ',' '\n'
```

Keys must be exactly `postgres-password` and `password`, matching
`postgresql.auth.secretKeys` in `values-common.yaml`.

**`docker push` fails partway on large layers**

Raise the Route timeout in `platform/route.yaml`
(`haproxy.router.openshift.io/timeout`).

**Docker login redirects to `http://` or an internal hostname**

Set **Administration → General → Custom Base URL** to the Route's
`https://` URL. There is no chart value for this — it is runtime config stored
in the database, which is why `values-ocprod.yaml` does not set it.

**ArgoCD shows permanent drift on a StatefulSet**

Expected if a PVC size changed; `volumeClaimTemplates` are immutable. See
[storage.md](storage.md#resizing).
