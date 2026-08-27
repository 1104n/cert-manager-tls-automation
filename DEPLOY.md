# Deployment Guide

## Prerequisites

- A Kubernetes cluster you can `kubectl apply` to.
- [cert-manager](https://cert-manager.io/docs/installation/) installed:
  ```bash
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
  ```
- **(Recommended)** [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) for cross-namespace trust distribution:
  ```bash
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm install trust-manager jetstack/trust-manager \
    --namespace cert-manager \
    --set app.trust.namespace=cert-manager
  
  # Verify it's running
  kubectl get deployment -n cert-manager -l app=trust-manager
  ```
  
  **What trust-manager does**: Automatically syncs the CA certificates from `cert-manager` namespace to any other namespace you label with `trust-bundle=shared-ca-bundle`. This is the recommended way to distribute trust anchors instead of manually copying secrets.

- **(Optional)** [Stakater Reloader](https://github.com/stakater/Reloader) for automatic pod restarts on cert rotation:
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/stakater/Reloader/master/deployments/kubernetes/reloader.yaml
  
  # Verify it's running
  kubectl get deployment -n default -l app=reloader
  ```

### What if I skip trust-manager?

If you don't install trust-manager, you'll need to manually distribute the intermediate CA certificate (`ca.crt`) to each namespace. Workloads will still work, but rotation updates will require manual re-distribution of the CA file.

## Before you apply anything

Every manifest in `manifests/` uses placeholders — `<namespace>`,
`<app-namespace>`, `<cluster-name>`. Replace them with your real values
first:

```bash
# from the repo root
grep -rl '<namespace>\|<app-namespace>\|<cluster-name>' manifests/ \
  | xargs sed -i 's/<namespace>/your-data-namespace/g; s/<app-namespace>/your-app-namespace/g; s/<cluster-name>/your-cluster-name/g'
```

Adjust `dnsNames` in `manifests/02-leaf-certificates.yaml` to match your
actual Service names — the values there are illustrative, not required
names.

## Deploy order

### Step 1: CA Hierarchy

```bash
# Apply root + intermediate CA and cluster-scoped issuers
kubectl apply -f manifests/01-ca-hierarchy.yaml

# Wait for both CAs to be Ready (this generates the certificates)
kubectl wait certificate/root-ca -n cert-manager --for=condition=Ready --timeout=120s
kubectl wait certificate/intermediate-ca -n cert-manager --for=condition=Ready --timeout=120s

# Verify
kubectl get certificate -n cert-manager
```

At this point, you have:
- `root-ca-secret` (20-year root, ECDSA P-384)
- `intermediate-ca-secret` (10-year intermediate, ECDSA P-384, signed by root)
- `shared-ca` ClusterIssuer (wraps intermediate-ca-secret, ready to sign leaf certs)

### Step 2: Leaf Certificates

```bash
# Create per-service certificates (redis, rabbitmq, minio, app, etc.)
kubectl apply -f manifests/02-leaf-certificates.yaml

# Wait for all leaf certs to be Ready
kubectl wait certificate -n <namespace> --all --for=condition=Ready --timeout=120s
kubectl wait certificate -n <app-namespace> --all --for=condition=Ready --timeout=120s

# Verify
kubectl get certificate -n <namespace>
kubectl get certificate -n <app-namespace>
```

Each leaf cert is now a Secret in its respective namespace (e.g., `redis-tls`, `rabbitmq-tls`, etc.).

### Step 3: Trust Bundle (if trust-manager is installed)

```bash
# Deploy the trust-manager Bundle resource
kubectl apply -f manifests/03-trust-bundle.yaml

# Label every namespace that needs the shared trust anchor
# This tells trust-manager to project the CA ConfigMap into these namespaces
kubectl label namespace <namespace> trust-bundle=shared-ca-bundle --overwrite
kubectl label namespace <app-namespace> trust-bundle=shared-ca-bundle --overwrite

# Verify the ConfigMap is present
kubectl get configmap shared-ca-bundle -n <namespace>
kubectl get configmap shared-ca-bundle -n <app-namespace>

# Show the contents (should be root + intermediate PEM chain)
kubectl get configmap shared-ca-bundle -n <namespace> -o jsonpath='{.data.ca-bundle\.crt}' | head -5
```

**What just happened**: 
- The `shared-ca-bundle` ConfigMap now exists in both namespaces
- It contains the root certificate + intermediate certificate in PEM format
- trust-manager will keep it in sync if the CAs rotate
- Any workload that needs to *verify* other service certs can mount this ConfigMap

### Step 4: Wire certificates into workloads

#### For operator-managed databases (e.g., Percona XtraDB Cluster)

```bash
# Merge the database block from manifests/04-service-mounts.yaml
# into your operator's Custom Resource (CR), then apply it
# The operator will handle cert rotation and mounting automatically

kubectl apply -f <your-database-cr>.yaml

# Wait for the operator-managed cert to be Ready
kubectl wait certificate -n <namespace> -l app.kubernetes.io/instance=<cluster-name> \
  --for=condition=Ready --timeout=180s
```

#### For redis, rabbitmq, minio, and your app

```bash
# For each workload (redis StatefulSet, rabbitmq StatefulSet, etc.),
# merge the relevant block from manifests/04-service-mounts.yaml into
# the workload's spec, then apply

# Example for redis:
kubectl apply -f <your-redis-statefulset>.yaml

# Trigger a rolling restart so pods pick up the new certs
kubectl rollout restart statefulset/redis -n <namespace>
kubectl rollout status statefulset/redis -n <namespace>

# Repeat for rabbitmq, minio, and your app
kubectl rollout restart statefulset/rabbitmq -n <namespace>
kubectl rollout status statefulset/rabbitmq -n <namespace>

kubectl rollout restart statefulset/minio -n <namespace>
kubectl rollout status statefulset/minio -n <namespace>

kubectl rollout restart deployment/app -n <app-namespace>
kubectl rollout status deployment/app -n <app-namespace>
```

## Verify

### CA hierarchy

```bash
kubectl get certificate -n cert-manager
# Expected: root-ca READY, intermediate-ca READY
```

### Leaf certificates

```bash
kubectl get certificate -n <namespace>
kubectl get certificate -n <app-namespace>
# Expected: all certificates show READY = True
```

### Certificate chain integrity

```bash
# Extract intermediate cert
kubectl get secret intermediate-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/intermediate.crt

# Extract a leaf cert
kubectl get secret redis-tls -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/redis-leaf.crt

# Verify the leaf is signed by the intermediate
openssl verify -CAfile /tmp/intermediate.crt /tmp/redis-leaf.crt
# Expected output: redis-leaf.crt: OK
```

### Leaf certificate's embedded CA

```bash
# Every leaf secret includes ca.crt (the intermediate, not the root)
diff <(kubectl get secret redis-tls -n <namespace> \
       -o jsonpath='{.data.ca\.crt}' | base64 -d) \
     /tmp/intermediate.crt
# Expected: no output (files are identical)
```

### Live TLS handshake test

```bash
# Test with redis (replace with your service)
kubectl run tls-test --rm -it --image=alpine/openssl -n <namespace> -- \
  s_client -connect redis.<namespace>.svc:6379 \
  -cert /etc/certs/redis/tls.crt \
  -key /etc/certs/redis/tls.key \
  -CAfile /etc/certs/redis/ca.crt
  
# Type: QUIT
# Expected: connection established, TLS handshake succeeds
```

### Trust bundle distribution (if trust-manager is installed)

```bash
# ConfigMap should exist in every labeled namespace
kubectl get configmap shared-ca-bundle -n <namespace>
kubectl get configmap shared-ca-bundle -n <app-namespace>

# Inspect the contents
kubectl get configmap shared-ca-bundle -n <namespace> \
  -o jsonpath='{.data.ca-bundle\.crt}' | wc -l
# Expected: two certificate blocks (root + intermediate)

# Check trust-manager's status
kubectl logs -n cert-manager -l app=trust-manager --tail=20
```

### Reloader monitoring (if installed)

```bash
# Verify Reloader is watching for secret changes
kubectl logs -n default -l app=reloader --tail=50 | grep -i "watching\|secret"

# Optionally, add Reloader annotations to your Deployments/StatefulSets:
# metadata:
#   annotations:
#     secret.reloader.stakater.com/reload: "redis-tls,rabbitmq-tls"
#     configmap.reloader.stakater.com/reload: "shared-ca-bundle"
```

## Trust Bundle Setup Details

### Why trust-manager?

Without trust-manager, distributing the CA certificate to multiple namespaces requires:
1. Manual copying of the secret across namespaces
2. Re-distribution every time the CA rotates
3. Workloads with direct access to the cert-manager namespace (security risk)

trust-manager solves this by:
- **Projecting a ConfigMap** (public cert only) instead of a Secret
- **Automatic syncing** when the source certificate updates
- **Least privilege**: workloads only need to read the ConfigMap in their own namespace

### How it works

The Bundle resource in `03-trust-bundle.yaml`:
```yaml
sources:
  - secret:
      name: root-ca-secret      # pulls root cert
      key: tls.crt
  - secret:
      name: intermediate-ca-secret # pulls intermediate cert
      key: tls.crt
target:
  configMap:
    key: ca-bundle.crt          # creates a combined PEM file
  namespaceSelector:
    matchLabels:
      trust-bundle: shared-ca-bundle  # only in labeled namespaces
```

Once a namespace is labeled `trust-bundle=shared-ca-bundle`, trust-manager will:
1. Create the `shared-ca-bundle` ConfigMap in that namespace
2. Populate it with the root + intermediate certificates
3. Watch for updates and sync automatically on rotation

### Mounting the bundle in your workload

In your Deployment/StatefulSet `spec`:
```yaml
volumes:
  - name: ca-trust
    configMap:
      name: shared-ca-bundle
containers:
  - name: myapp
    volumeMounts:
      - name: ca-trust
        mountPath: /etc/ca
        readOnly: true
    # Your app can now verify peer certs using /etc/ca/ca-bundle.crt
```

### Optional: Auto-restart on bundle update

With Stakater Reloader, add annotations to auto-restart workloads when the trust bundle updates:
```yaml
metadata:
  annotations:
    configmap.reloader.stakater.com/reload: "shared-ca-bundle"
```

This is useful if your app loads `ca.crt` at startup and doesn't watch for changes (most apps do this).

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
6. **Install trust-manager** to automate CA distribution. If you skip it,
   manually distribute the intermediate CA's public cert (`ca.crt`) to all
   namespaces that need it.

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
- **Trust-manager gotcha**: If a namespace is labeled but trust-manager pod 
  is not running or doesn't have permissions, the ConfigMap won't be created.
  Check `kubectl logs -n cert-manager -l app=trust-manager` for errors.
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
