# Storage

## The situation on this cluster

`nfs-client` (NFS subdir external provisioner) is the only StorageClass, and it
is the default:

```
NAME                   PROVISIONER                                      DEFAULT
nfs-client             cluster.local/nfs-subdir-external-provisioner    yes
```

Both PVCs therefore land on NFS:

| PVC | Size | Contents |
|---|---|---|
| `artifactory-volume-jcr-artifactory-0` | 200Gi | binary filestore, logs, config |
| `data-jcr-postgresql-0` | 50Gi | PostgreSQL data directory |

## Artifactory's filestore on NFS: fine

This is a supported, common configuration — it is how Artifactory HA shares a
filestore between nodes. Artifactory writes immutable, checksum-addressed blobs
and does not rely on POSIX locking semantics for them.

The one tuning item is `fsGroupChangePolicy`, set to `OnRootMismatch` in
`values-common.yaml`. The default (`Always`) makes the kubelet recursively
`chown` the entire volume on every pod start. Over NFS, with a filestore of any
size, that turns into a multi-minute startup penalty that grows as the registry
fills. `OnRootMismatch` only fixes permissions when the volume root is wrong,
which is the case that actually needs fixing.

## PostgreSQL on NFS: the real risk

**This is the item to resolve before this deployment is production-grade.**

A PostgreSQL data directory on NFS is not a configuration the PostgreSQL
project or JFrog recommends. The concerns, in order of how likely they are to
hurt:

1. **Durability.** PostgreSQL's crash-safety depends on `fsync()` actually
   committing to stable storage before it acknowledges a commit. Over NFS that
   guarantee depends on the export's write-cache and `sync`/`async` settings.
   An `async` export will happily lose acknowledged transactions on a server
   crash, and PostgreSQL has no way to detect it.
2. **Locking.** PostgreSQL uses advisory file locks to ensure a single
   postmaster owns a data directory. NFS lock behaviour varies with the server
   and NFS version. A stale lock after an ungraceful pod termination can leave
   the StatefulSet unable to restart; worse, a failure of lock enforcement
   risks two postmasters on one data directory, which corrupts it.
3. **Performance.** WAL writes are small, synchronous and serialised — the
   workload NFS handles worst. It shows up as slow Artifactory metadata
   operations rather than an obvious database problem.

Artifactory keeps all of its metadata here: repository config, permissions,
tokens, artifact properties, build info. The filestore is recoverable by
re-pushing artifacts. The database is not.

### Options, best first

**1. External managed PostgreSQL (recommended).** Point the chart at an
existing PostgreSQL 13+ instance and stop running one in-cluster:

```yaml
artifactory:
  postgresql:
    enabled: false
  database:
    type: postgresql
    driver: org.postgresql.Driver
    url: jdbc:postgresql://pg.example.internal:5432/artifactory
    secrets:
      user:
        name: jfrog-jcr-db
        key: db-user
      password:
        name: jfrog-jcr-db
        key: db-password
```

Then drop `jfrog-jcr-postgresql` from `platform/rbac.yaml` and
`platform/serviceaccounts.yaml`.

**2. Block storage for the database.** If any block-mode StorageClass can be
added to the cluster (ODF/Ceph RBD, vSphere, iSCSI, LVM), use it for
PostgreSQL only and leave the filestore on NFS:

```yaml
artifactory:
  postgresql:
    primary:
      persistence:
        storageClass: <block-storage-class>
```

This is usually the smallest change that removes the risk.

**3. Stay on NFS, with eyes open.** If this is a non-critical internal
registry, confirm with whoever runs the NFS server that the export is `sync`
(not `async`), take regular `pg_dump` backups, and accept that an ungraceful
node failure may require restoring from one.

### Checking the export

```bash
oc -n jfrog-jcr get pvc data-jcr-postgresql-0 \
  -o jsonpath='{.spec.volumeName}'
oc get pv <name> -o jsonpath='{.spec.nfs}{"\n"}{.spec.mountOptions}{"\n"}'
```

An export without `sync`, or mount options including `async`, means
acknowledged commits can be lost.

## Resizing

`nfs-client` has `allowVolumeExpansion: true`, so PVCs can grow:

```bash
oc -n jfrog-jcr patch pvc artifactory-volume-jcr-artifactory-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"400Gi"}}}}'
```

Update the size in `values-ocprod.yaml` in the same change so Git stays the
source of truth. A StatefulSet's `volumeClaimTemplates` are immutable, so
ArgoCD cannot apply the new size itself — this is why
`application-registry.yaml` adds an `ignoreDifferences` entry for
`/spec/volumeClaimTemplates`. Without it, ArgoCD would report drift it can
never resolve.
