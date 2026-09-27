# Installing Agent Substrate on a Gardener Shoot Cluster

This guide covers installing Agent Substrate (`ate-setup --gardener`) on a Gardener-managed
AWS Shoot cluster. It was validated on pb3-dev (k8s 1.36.3, Garden Linux 2150.10.0, 3× m5.large
workers, Cilium CNI) in September 2026.

## Prerequisites

- A Gardener Shoot on k8s **1.36.3+** (see [Kubernetes version requirements](#kubernetes-version-requirements))
- Access to the Gardener project API server (kubeconfig for the Garden cluster)
- Access to the Shoot cluster (`kubeconfig-gardenlogin--<project>--<shoot>.yaml`)
- Docker or compatible runtime for building images (Apple Silicon: always `linux/amd64`)
- `kubectl`, `go` (1.22+), `ko` installed

## Kubernetes Version Requirements

Substrate requires three beta APIs that Gardener does not enable by default:

| API / Feature | Minimum version | Notes |
|---|---|---|
| `ClusterTrustBundle` | 1.27 (alpha) / 1.34 (beta) | Used by podcertificate-controller for CA distribution |
| `ClusterTrustBundleProjection` | 1.29 (alpha) / 1.34 (beta) | Needed to mount clusterTrustBundle as a projected volume |
| `PodCertificateRequest` | **1.36** (beta, first version with this API) | Used by podcertificate-controller to issue pod TLS certs |

**Minimum supported Kubernetes version: 1.36.** Gardener enforces no-skip-minor upgrades; upgrade
1.34 → 1.35 → 1.36 sequentially.

## Step 1 — Enable Feature Gates on the Shoot

Apply this patch to the Shoot CR in the Garden cluster. Replace `<shoot-namespace>` and `<shoot-name>`:

```bash
GARDEN_KUBECONFIG=kubeconfig-garden-<project>.yaml
SHOOT_NS=<shoot-namespace>          # e.g. garden-pb-aws
SHOOT_NAME=<shoot-name>             # e.g. pb3-dev

kubectl --kubeconfig $GARDEN_KUBECONFIG -n $SHOOT_NS patch shoot $SHOOT_NAME \
  --type=merge --patch-file=/dev/stdin <<'PATCH'
{
  "spec": {
    "kubernetes": {
      "version": "1.36.3",
      "kubeAPIServer": {
        "featureGates": {
          "ClusterTrustBundle": true,
          "ClusterTrustBundleProjection": true,
          "PodCertificateRequest": true
        },
        "runtimeConfig": {
          "certificates.k8s.io/v1beta1": true,
          "certificates.k8s.io/v1beta1/podcertificaterequests": true
        }
      },
      "kubeControllerManager": {
        "featureGates": {
          "ClusterTrustBundle": true,
          "PodCertificateRequest": true
        }
      },
      "kubelet": {
        "featureGates": {
          "ClusterTrustBundle": true,
          "ClusterTrustBundleProjection": true,
          "PodCertificateRequest": true
        }
      }
    }
  }
}
PATCH
```

Wait for Gardener to reconcile the Shoot (typically 5–10 min). All nodes will be rolled.
Verify:

```bash
kubectl --kubeconfig $GARDEN_KUBECONFIG -n $SHOOT_NS get shoot $SHOOT_NAME \
  -o jsonpath='{.status.lastOperation.state}' && echo
# Must be: Succeeded
```

### Why each component needs different gates

| Component | Gates needed | Why |
|---|---|---|
| kube-apiserver | ClusterTrustBundle, ClusterTrustBundleProjection, PodCertificateRequest | Serves the APIs; ClusterTrustBundleProjection must be on the API server or the `clusterTrustBundle` projected volume source is silently stored as `{}` in etcd |
| kube-controller-manager | ClusterTrustBundle, PodCertificateRequest | Signs PodCertificateRequests |
| kubelet | ClusterTrustBundle, ClusterTrustBundleProjection, PodCertificateRequest | Mounts projected volumes; needs both projection gates or volume never populates |

**ClusterTrustBundleProjection is required on BOTH apiserver AND kubelet.** Enabling it only on
the apiserver causes the projected volume source to be stored as empty `{}` in etcd, and the
kubelet never populates the volume (silent failure — no error, just a missing file).

### runtimeConfig vs featureGates

For `PodCertificateRequest`, you need BOTH:
- `featureGates.PodCertificateRequest: true` — gates the code path
- `runtimeConfig["certificates.k8s.io/v1beta1/podcertificaterequests"]: true` — actually enables
  serving the API endpoint (on k8s 1.36 it is beta but not yet served by default)

Setting only the feature gate is not enough; the API server will refuse watches on the resource.

## Step 2 — Configure the In-Cluster Registry

Gardener Shoot clusters have an in-cluster registry accessible as
`registry.<shoot-name>.<project>.shoot.canary.k8s-hana.ondemand.com`. Use this for all
images — no ECR credentials needed.

```bash
export KO_DOCKER_REPO="registry.<shoot-name>.<project>.shoot.canary.k8s-hana.ondemand.com/substrate"
```

## Step 3 — Deploy

From the substrate repo root:

```bash
export KO_DOCKER_REPO="registry.<shoot-name>.<project>.shoot.canary.k8s-hana.ondemand.com/substrate"
export EXPECTED_JWT_ISSUER="https://api.<shoot-name>.<project>.internal.canary.k8s.ondemand.com"
export KUBECONFIG=/path/to/kubeconfig-gardenlogin--<project>--<shoot-name>.yaml

go run ./cmd/ate-setup \
  --gardener \
  --no-dev-env \
  --kubeconfig "$KUBECONFIG" \
  --context "<shoot-name>-external" \
  --rollout-timeout 300s \
  deploy ate-system
```

On Apple Silicon, `ko` automatically builds `linux/amd64` because `applyGardenerDefaults()`
sets `KO_DEFAULTPLATFORMS=linux/amd64`. Do not override this.

First run takes ~15 min (cross-compile 5 Go binaries + build Envoy dataplane image from Rust).
Subsequent runs (cached layers) take ~3 min.

### What gets deployed

| Component | Namespace | Notes |
|---|---|---|
| podcertificate-controller | podcertificate-controller-system | Signs PodCertificateRequests; issues ClusterTrustBundles |
| ate-api-server | ate-system | Serves ate-api (gRPC + REST); backed by postgres |
| ate-controller | ate-system | Reconciles WorkerPool CRs |
| atenet-router | ate-system | Data plane: routes actor traffic |
| atenet-egress | ate-system | Data plane: egress proxy |
| atelet | ate-system | DaemonSet; one pod per worker node; manages sandbox lifecycle |
| postgres | ate-system | StatefulSet; TLS via podcertificate |
| rustfs | ate-system | S3-compatible in-cluster object store (snapshots) |

## Step 4 — Verify

```bash
kubectl --kubeconfig $KUBECONFIG get pods -n ate-system
kubectl --kubeconfig $KUBECONFIG get pods -n podcertificate-controller-system
```

All pods should be `Running`. Postgres is 2/2 (contains sidecar). atenet-* are 2/2 (envoy
sidecar). atelet should show one pod per worker node.

## Step 5 — Smoke Test

```bash
# Build the ateom-gvisor worker image
KO_DOCKER_REPO="registry.<shoot-name>.<project>.shoot.canary.k8s-hana.ondemand.com/substrate"
cd /path/to/substrate
ATEOM_IMAGE=$($(go env GOPATH)/bin/ko build --platform linux/amd64 ./cmd/ateom-gvisor)

# Create a WorkerPool
kubectl --kubeconfig $KUBECONFIG apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ate-smoke-test
---
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: smoke-pool
  namespace: ate-smoke-test
  labels:
    workload: smoke
spec:
  replicas: 1
  workerImage: ${ATEOM_IMAGE}
EOF

# Wait for ready
kubectl --kubeconfig $KUBECONFIG wait --for=condition=Ready pods -n ate-smoke-test --all --timeout=120s

# Check status
kubectl --kubeconfig $KUBECONFIG get workerpool smoke-pool -n ate-smoke-test

# Clean up
kubectl --kubeconfig $KUBECONFIG delete namespace ate-smoke-test
```

Expected output: WorkerPool `readyReplicas: 1`.

## Gardener-Specific Gotchas

### 1. Cilium hostPort 9090 conflict

Cilium's DaemonSet on Gardener nodes uses `hostPort: 9090` for its Prometheus metrics on **all**
nodes. The atelet DaemonSet also wants port 9090, making it impossible to schedule.

**Fix (already in the `gardener/atelet` overlay):** atelet's prometheus port is remapped from
`hostPort: 9090` to `hostPort: 19090`. The container still listens on 9090 internally; only
the host-side port forwarding is remapped. Kubernetes uses `containerPort` as the strategic-merge
key for container ports, so patching `containerPort: 9090` with `hostPort: 19090` replaces the
entry in-place without creating a duplicate.

### 2. ClusterTrustBundleProjection silent failure

If you apply substrate manifests before enabling `ClusterTrustBundleProjection` on the apiserver,
the projected volume source gets stored as `{}` in etcd. Re-enabling the feature gate does NOT fix
already-stored objects — you must delete and re-create all StatefulSets and Deployments that use
`clusterTrustBundle` projected volume sources (postgres, atelet, ate-api-server, atenet-*).

Symptom: pods start but fail with `No such file or directory` on `/run/*/trust-bundle.pem`.

### 3. PodCertificateRequest needs both featureGates and runtimeConfig

On k8s 1.36, `PodCertificateRequest` is beta but not served by default. You need:
- `kubeAPIServer.featureGates.PodCertificateRequest: true`
- `kubeAPIServer.runtimeConfig["certificates.k8s.io/v1beta1/podcertificaterequests"]: true`

Symptom (missing runtimeConfig): `failed to list *v1beta1.PodCertificateRequest: the server could
not find the requested resource`.

### 4. Sequential upgrade requirement

Gardener enforces no-skip-minor-version upgrades. If you are on 1.34:
1. Upgrade to 1.35.x first, wait for Succeeded
2. Upgrade to 1.36.x, wait for Succeeded
3. Apply feature gates (can be done at any version before 1.36)

### 5. postgres CPU pressure on small nodes

The base postgres.yaml requests 2 vCPU and limits to 16 vCPU. The `kind/postgres` overlay used
by `--gardener` reduces this to 250m/2. On m5.large nodes (2 vCPU each, ~80% pre-allocated by
system components), the 250m request still fits but barely. If the cluster auto-scales down while
postgres is pending, it may get stuck. Use `--gardener` (not base postgres) always.

## S3 / rustfs Storage

The `--gardener` profile deploys rustfs (an in-cluster S3-compatible store) in `ate-system` and
configures all components to use it:

- Endpoint: `http://rustfs.ate-system.svc:9000`
- Credentials: `rustfsadmin` / `rustfsadmin` (change for production)
- Bucket: `ate-snapshots` (created by the `rustfs-bucket-init` Job)

Actor snapshots are stored at `s3://ate-snapshots/<atespace>/<actor>/`.

## Modifications to ate-setup (Gardener Profile)

The following changes to `cmd/ate-setup` implement Gardener support:

| File | Change |
|---|---|
| `internal/config/config.go` | Added `Gardener bool` to Config/Options; `applyGardenerDefaults()` sets `KODefaultPlatforms=linux/amd64` and `BucketName=ate-snapshots` |
| `internal/cmd/root.go` | Added `--gardener` flag |
| `internal/steps/overlay.go` | `SystemOverlay()` returns `manifests/ate-install/gardener` for Gardener |
| `internal/steps/deploy.go` | `DeployAtelet()` uses `gardener/atelet` kustomization overlay |
| `internal/steps/postgres.go` | `postgresManifestPath()` uses `kind/postgres` overlay for both Kind and Gardener |
| `manifests/ate-install/gardener/` | New overlay directory (see below) |

## Gardener Overlay Structure

```
manifests/ate-install/gardener/
├── kustomization.yaml          # Full system bundle: ate-api-server, ate-controller,
│                               # atenet-router, ate-otel-config, rustfs, otel-collector,
│                               # prometheus; patches ate-api-server for S3 storage
├── atelet/
│   └── kustomization.yaml      # atelet overlay: no GCP auth, S3 backend,
│                               # prometheus hostPort remapped 9090→19090
├── ate-otel-config.yaml        # OpenTelemetry config (no GCP collector endpoint)
├── otel-collector.yaml         # In-cluster otel-collector Deployment
├── prometheus.yaml             # In-cluster Prometheus for metrics
└── rustfs.yaml                 # rustfs (S3-compatible store) Deployment + Service
```
