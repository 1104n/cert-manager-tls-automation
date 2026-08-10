# TLS Certificate Automation with cert-manager

A reusable pattern for issuing, rotating, and distributing internal TLS
certificates across a Kubernetes cluster using [cert-manager](https://cert-manager.io/)
and [trust-manager](https://cert-manager.io/docs/trust/trust-manager/), with
automatic pod restarts on rotation via [Stakater Reloader](https://github.com/stakater/Reloader).

It builds a two-tier CA (root → intermediate) and issues short-lived leaf
certificates for every backend service — database, cache, message broker,
object storage, and your application — all signed by the same intermediate
CA so every service trusts every other service without any manual cert
handling.

## Architecture

```
cert-manager (ns: cert-manager)
├── selfsigned-bootstrap (ClusterIssuer) → signs the root only
├── root-ca (Certificate, 20y)           → secret: root-ca-secret
├── root-ca-issuer (ClusterIssuer)       → wraps the root secret
├── intermediate-ca (Certificate, 10y)   → secret: intermediate-ca-secret
└── shared-ca (ClusterIssuer)            → wraps the intermediate secret,
                                            signs every leaf cert below
        │
        ├── mysql        (operator-managed, or manual Certificate)
        ├── redis-tls     (ns: <namespace>)      renewBefore: 720h  (30d)
        ├── rabbitmq-tls  (ns: <namespace>)      renewBefore: 720h  (30d)
        ├── minio-tls     (ns: <namespace>)      renewBefore: 720h  (30d)
        └── app-client-tls(ns: <app-namespace>)  renewBefore: 360h  (15d)
```

`root-ca` and `intermediate-ca` are both `isCA: true`, ECDSA P-384 keys,
`rotationPolicy: Always`. Leaf certs are RSA 2048, `isCA: false`, all issued
by the single `shared-ca` ClusterIssuer.

**Why ECDSA P-384 for the CA and RSA 2048 for leaves?**
- ECDSA P-384 is strong and fast for CA signing/verification, well suited
  to an internal Kubernetes CA.
- RSA 2048 is the safer default for leaf certs — every common database,
  broker, and TLS client library supports it without extra configuration,
  and it comfortably meets current TLS server-certificate guidance at
  lower CPU/storage cost than RSA 4096.

## Per-service cert summary

| Service | Secret | Duration | renewBefore | Managed by |
|---|---|---|---|---|
| database (operator-managed) | `<cluster>-ssl`, `<cluster>-ssl-internal` | 2160h (90d) | operator default (~30d) | your DB operator |
| redis | `redis-tls` | 2160h (90d) | 720h (30d) | manual `Certificate` |
| rabbitmq | `rabbitmq-tls` | 2160h (90d) | 720h (30d) | manual `Certificate` |
| minio | `minio-tls` | 2160h (90d) | 720h (30d) | manual `Certificate` |
| app | `app-client-tls` | 2160h (90d) | 360h (15d) | manual `Certificate` |

Every `<namespace>` / `<app-namespace>` / `<cluster>` placeholder in this
repo is yours to fill in — see [DEPLOY.md](./DEPLOY.md) for the full
walkthrough.

## Why no cascading restarts are needed

TLS validation checks one thing: *is this leaf signed by a CA I trust?* It
never compares against the previous leaf. So when a database rotates its
cert, a downstream app validates the new leaf identically to the old one —
no action needed on the app side, and no action needed further downstream
either, as long as everything still trusts the same intermediate CA.

The only thing that actually breaks at rotation time is the **TCP
connection** (old socket dies when the pod restarts to pick up the new
cert), not the cert itself. That's an application-layer concern, handled by
normal reconnect/retry logic (e.g. `pool_pre_ping` for SQL connection
pools, `retry_on_timeout` for Redis clients, robust/auto-reconnect wrappers
for AMQP clients).

This reasoning holds only as long as every service is signed by the same
`shared-ca` issuer. If a service ever moves to a different issuer, it stops
validating against the shared trust anchor regardless of restart timing.

## Repository layout

```
manifests/
  01-ca-hierarchy.yaml      # root + intermediate CA, shared ClusterIssuer
  02-leaf-certificates.yaml # per-service Certificate objects
  03-trust-bundle.yaml      # trust-manager Bundle for cross-namespace trust
  04-service-mounts.yaml    # copy-paste snippets for wiring certs into workloads
examples/
  redis-cluster-migrate.py  # reference script for migrating between two
                             # TLS-enabled Redis Clusters
```

See [DEPLOY.md](./DEPLOY.md) for prerequisites, the exact apply order,
verification steps, and troubleshooting notes.
