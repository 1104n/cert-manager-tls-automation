# Deployment Guide

## Prerequisites

- A Kubernetes cluster you can `kubectl apply` to.
- [cert-manager](https://cert-manager.io/docs/installation/) installed:
  ```bash
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
  ```
- (Optional, for cross-namespace trust distribution) [trust-manager](https://cert-manager.io/docs/trust/trust-manager/):
  ```bash
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm install trust-manager jetstack/trust-manager \
    --namespace cert-manager \
    --set app.trust.namespace=cert-manager
  ```
- (Optional, for automatic pod restarts on cert rotation) [Stakater Reloader](https://github.com/stakater/Reloader):
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/stakater/Reloader/master/deployments/kubernetes/reloader.yaml
  ```

## Before you apply anything

Every manifest in `manifests/` uses placeholders — `<namespace>`,
`<app-namespace>`, `<cluster-name>`. Replace them with your real values
first:

```bash
# from the repo root
grep -rl '<namespace>\|<app-namespace>\|<cluster-name>' manifests/ \
  | xargs sed -i 's/<namespace>/your-data-namespace/g; s/<app-namespace>/your-app-namespace/g'
```

Adjust `dnsNames` in `manifests/02-leaf-certificates.yaml` to match your
actual Service names — the values there are illustrative, not required
names.

## Deploy order

```bash
# 1. CA hierarchy (cert-manager namespace, cluster-scoped issuers)
kubectl apply -f manifests/01-ca-hierarchy.yaml

# 2. wait for root + intermediate to be Ready before proceeding
kubectl wait certificate/root-ca -n cert-manager --for=condition=Ready --timeout=120s
kubectl wait certificate/intermediate-ca -n cert-manager --for=condition=Ready --timeout=120s

# 3. leaf certs for every non-operator-managed service
kubectl apply -f manifests/02-leaf-certificates.yaml
kubectl wait certificate -n <namespace> --all --for=condition=Ready --timeout=120s
kubectl wait certificate -n <app-namespace> --all --for=condition=Ready --timeout=120s

# 4. (optional) trust bundle for cross-namespace verification
kubectl apply -f manifests/03-trust-bundle.yaml
kubectl label namespace <namespace> trust-bundle=shared-ca-bundle
kubectl label namespace <app-namespace> trust-bundle=shared-ca-bundle

# 5. for an operator-managed database: merge the block from
#    manifests/04-service-mounts.yaml into your operator's CR, then apply it
kubectl apply -f <your-database-cr>.yaml
kubectl wait certificate -n <namespace> -l app.kubernetes.io/instance=<cluster-name> \
  --for=condition=Ready --timeout=180s

# 6. merge the remaining manifests/04-service-mounts.yaml blocks (redis/
#    rabbitmq/minio/your app) into your StatefulSets/Deployments, apply,
#    then roll out each one
kubectl rollout restart statefulset/redis -n <namespace>
kubectl rollout restart statefulset/rabbitmq -n <namespace>
kubectl rollout restart statefulset/minio -n <namespace>
kubectl rollout restart deployment/app -n <app-namespace>
```

## Verify

```bash
# CA hierarchy ready
kubectl get certificate -n cert-manager

# leaf certs ready, correct namespace
kubectl get certificate -n <namespace>
kubectl get certificate -n <app-namespace>

# chain is intact: leaf signed by intermediate
kubectl get secret intermediate-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > /tmp/intermediate.crt

kubectl get secret redis-tls -n <namespace> -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > /tmp/redis-leaf.crt

openssl verify -CAfile /tmp/intermediate.crt /tmp/redis-leaf.crt
# -> redis-leaf.crt: OK

# confirm ca.crt in every leaf secret matches the intermediate cert
diff <(kubectl get secret redis-tls -n <namespace> -o jsonpath='{.data.ca\.crt}' | base64 -d) \
     /tmp/intermediate.crt
# -> no output = identical, as expected

# live handshake test, e.g. redis
kubectl run tls-test --rm -it --image=alpine/openssl -n <namespace> -- \
  s_client -connect redis.<namespace>.svc:6379 -cert /etc/certs/redis/tls.crt \
  -key /etc/certs/redis/tls.key -CAfile /etc/certs/redis/ca.crt

# trust-manager bundle synced (if used)
kubectl get configmap shared-ca-bundle -n <namespace>
kubectl get configmap shared-ca-bundle -n <app-namespace>

# Reloader watching the right secrets (if used)
kubectl logs -n <reloader-namespace> -l app=reloader --tail=50
```

## How to use this in your own repo

1. Copy `manifests/` and `examples/` into your infra repo (or `git subtree`
   this repo in).
2. Do the placeholder replacement above.
3. Add/remove leaf `Certificate` blocks in `02-leaf-certificates.yaml` to
   match your actual service list — the four examples given (mysql, redis,
   rabbitmq, minio) plus an app-facing client cert are a starting set, not
   a fixed list.
4. If a service is managed by a Kubernetes operator that supports pointing
   at an external issuer, prefer that over a hand-authored `Certificate` —
   see the note at the top of `02-leaf-certificates.yaml` and the first
   block in `04-service-mounts.yaml`.
5. Wire Reloader annotations onto any workload that doesn't hot-reload
   certs from a changed Secret on its own (most databases/brokers don't).

## Gotchas

- Don't combine an operator's own `issuerConf`-style external-issuer field
  with manually setting its secret name fields to certs you authored
  yourself — pick one path, not both.
- `ClusterIssuer.spec.ca.secretName` must live in cert-manager's
  cluster-resource-namespace (default `cert-manager`). Check with:
  `kubectl get deploy cert-manager -n cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}'`
- A leaf secret's `ca.crt` is the **intermediate** cert, not the root.
  That's intentional — every service trusts the intermediate directly, so
  the root never needs to be distributed to application workloads.
- Redis/RabbitMQ/MinIO do **not** hot-reload certs from a changed Secret on
  their own — install Reloader (or equivalent) on these workloads, or
  budget for a rolling restart on every renewal.
- MinIO requires literal filenames `public.crt` / `private.key` /
  `CAs/ca.crt` — handled via the `items` remap in
  `04-service-mounts.yaml`; don't mount the secret directly.
- A single app-facing client cert can be reused across multiple backends as
  long as they all trust the same `shared-ca`. If you need per-backend
  identity (e.g. CN-based ACLs), split it into separate `Certificate`
  objects instead.
- The intermediate CA (`intermediate-ca-secret`) has a 1y `renewBefore` on
  a 10y duration. When it eventually rotates, that's the one event where
  **every** consumer needs the new trust anchor — trust roots aren't
  backward-compatible the way leaf certs are. `trust-manager` keeps the
  distributed *file*/ConfigMap in sync automatically, but any service that
  loads `ca.crt` into memory once at startup (rather than watching the
  file) will still need a restart at that point. Years out for most
  durations here, but don't assume the "no cascade needed" reasoning in
  the README extends to a CA rotation.
- Some operators need a one-time patch to avoid startup issues on their
  own internal CA cert's renewal, e.g.:
  ```bash
  kubectl patch certificate <operator-managed-ca-cert> -n <namespace> \
    --type=merge -p '{"spec":{"privateKey":{"rotationPolicy":"Never"}}}'
  ```
  Check your specific operator's docs/issue tracker before assuming this
  applies to you.
