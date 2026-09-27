#!/usr/bin/env bash
# install-gardener.sh — Install Agent Substrate on a Gardener Shoot and run
# the counter demo. Works on any Shoot created from hack/gardener/shoot-substrate.yaml.
#
# Usage:
#   export GARDEN_KUBECONFIG=/path/to/kubeconfig-garden-<project>.yaml
#   export SHOOT_NAME=pb4-substrate
#   export SHOOT_NS=garden-pb-aws
#   bash hack/gardener/install-gardener.sh
#
# To only install (skip demo):
#   bash hack/gardener/install-gardener.sh --install-only
#
# To only run the demo (substrate already installed):
#   bash hack/gardener/install-gardener.sh --demo-only
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# ── Config ────────────────────────────────────────────────────────────────────
GARDEN_KUBECONFIG="${GARDEN_KUBECONFIG:?set GARDEN_KUBECONFIG}"
SHOOT_NAME="${SHOOT_NAME:?set SHOOT_NAME}"
SHOOT_NS="${SHOOT_NS:-garden-pb-aws}"

INSTALL_ONLY=false
DEMO_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --install-only) INSTALL_ONLY=true ;;
    --demo-only)    DEMO_ONLY=true ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "▶ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

# ── Step 1: wait for the Shoot to be ready ───────────────────────────────────
wait_shoot() {
  log "Waiting for Shoot $SHOOT_NAME to reach Succeeded …"
  while true; do
    state=$(kubectl --kubeconfig "$GARDEN_KUBECONFIG" get shoot "$SHOOT_NAME" \
      -n "$SHOOT_NS" -o jsonpath='{.status.lastOperation.state}' 2>/dev/null || true)
    prog=$(kubectl --kubeconfig "$GARDEN_KUBECONFIG" get shoot "$SHOOT_NAME" \
      -n "$SHOOT_NS" -o jsonpath='{.status.lastOperation.progress}' 2>/dev/null || true)
    if [[ "$state" == "Succeeded" ]]; then
      log "Shoot is ready."
      break
    elif [[ "$state" == "Failed" ]]; then
      die "Shoot reached Failed state."
    fi
    echo "  … ${prog:-?}% (${state:-pending})"
    sleep 30
  done
}

# ── Step 2: get shoot kubeconfig ─────────────────────────────────────────────
shoot_kubeconfig() {
  # gardenlogin kubeconfig follows the naming convention used in this repo
  local kc="$ROOT/kubeconfig-gardenlogin--${SHOOT_NS#garden-}--${SHOOT_NAME}.yaml"
  if [[ ! -f "$kc" ]]; then
    # Look in the container-hosting repo directory too (where kubeconfigs live)
    local alt
    for dir in "$ROOT" "$(dirname "$ROOT")/container-hosting" "$HOME"; do
      alt="$dir/kubeconfig-gardenlogin--${SHOOT_NS#garden-}--${SHOOT_NAME}.yaml"
      if [[ -f "$alt" ]]; then kc="$alt"; break; fi
    done
  fi
  if [[ ! -f "$kc" ]]; then
    die "Shoot kubeconfig not found at $kc — generate it with gardenlogin and set SHOOT_KC"
  fi
  echo "$kc"
}

# ── Step 3: derive registry + JWT issuer from shoot ──────────────────────────
shoot_registry() {
  local domain
  domain=$(kubectl --kubeconfig "$GARDEN_KUBECONFIG" get shoot "$SHOOT_NAME" \
    -n "$SHOOT_NS" -o jsonpath='{.status.dns.domain}' 2>/dev/null \
    || kubectl --kubeconfig "$GARDEN_KUBECONFIG" get shoot "$SHOOT_NAME" \
      -n "$SHOOT_NS" -o jsonpath='{.spec.dns.domain}' 2>/dev/null)
  echo "registry.${domain}/substrate"
}

shoot_jwt_issuer() {
  kubectl --kubeconfig "$GARDEN_KUBECONFIG" get shoot "$SHOOT_NAME" \
    -n "$SHOOT_NS" \
    -o jsonpath='{.status.advertisedAddresses[?(@.name=="internal")].url}'
}

shoot_context() {
  # gardenlogin kubeconfig context is <garden-namespace>--<shoot-name>-external
  echo "${SHOOT_NS}--${SHOOT_NAME}-external"
}

# ── Main ──────────────────────────────────────────────────────────────────────
if ! $DEMO_ONLY; then
  wait_shoot

  # Locate or build shoot kubeconfig
  SHOOT_KC="${SHOOT_KC:-$(shoot_kubeconfig)}"
  [[ -f "$SHOOT_KC" ]] || die "Shoot kubeconfig not found: $SHOOT_KC — set SHOOT_KC manually"

  export KO_DOCKER_REPO="${KO_DOCKER_REPO:-$(shoot_registry)}"
  export EXPECTED_JWT_ISSUER="${EXPECTED_JWT_ISSUER:-$(shoot_jwt_issuer)}"
  KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-$(shoot_context)}"

  log "KO_DOCKER_REPO  = $KO_DOCKER_REPO"
  log "JWT_ISSUER      = $EXPECTED_JWT_ISSUER"
  log "KUBECTL_CONTEXT = $KUBECTL_CONTEXT"
  log "SHOOT_KC        = $SHOOT_KC"

  log "Running ate-setup deploy ate-system …"
  go run ./cmd/ate-setup \
    --gardener \
    --no-dev-env \
    --kubeconfig "$SHOOT_KC" \
    --context "$KUBECTL_CONTEXT" \
    --rollout-timeout 300s \
    deploy ate-system

  log "✓ ate-system installed."
fi

if $INSTALL_ONLY; then
  log "Install-only mode — done."
  exit 0
fi

# ── Demo: counter ─────────────────────────────────────────────────────────────
log "=== Running counter demo ==="

SHOOT_KC="${SHOOT_KC:-}"
[[ -n "$SHOOT_KC" ]] || SHOOT_KC="$(shoot_kubeconfig)"
[[ -f "$SHOOT_KC" ]] || die "Shoot kubeconfig not found: $SHOOT_KC — set SHOOT_KC"

export KO_DOCKER_REPO="${KO_DOCKER_REPO:-$(shoot_registry)}"
export BUCKET_NAME="ate-snapshots"           # rustfs bucket (already exists)
export AWS_REGION="us-east-1"
export AWS_ENDPOINT_URL="http://rustfs.ate-system.svc:9000"
export AWS_S3_USE_PATH_STYLE="true"
export AWS_ACCESS_KEY_ID="rustfsadmin"
export AWS_SECRET_ACCESS_KEY="rustfsadmin"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-$(shoot_context)}"
KA="kubectl ate --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT"
KCT="kubectl --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT"

SUBSTRATE_VERSION=$(go run ./cmd/ate-setup version 2>/dev/null | awk '{print $1}' || git rev-parse --short HEAD)

# 1. Build ateom-gvisor worker image
log "Building ateom-gvisor image …"
ATEOM_IMAGE=$($(go env GOPATH)/bin/ko build --platform linux/amd64 ./cmd/ateom-gvisor)
log "  ateom-gvisor: $ATEOM_IMAGE"

# 2. Build counter app image
log "Building counter app image …"
COUNTER_IMAGE=$($(go env GOPATH)/bin/ko build --platform linux/amd64 ./demos/counter)
log "  counter: $COUNTER_IMAGE"

# 3. Apply WorkerPool
log "Applying counter WorkerPool …"
$KCT apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ate-demo-counter
---
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: counter
  namespace: ate-demo-counter
  labels:
    workload: counter
spec:
  replicas: 3
  workerImage: ${ATEOM_IMAGE}
  template:
    resources:
      limits:
        cpu: "1"
        memory: 1Gi
      requests:
        cpu: 250m
        memory: 1Gi
EOF

log "Waiting for counter WorkerPool to be ready …"
$KCT rollout status deployment/counter -n ate-demo-counter --timeout=300s

# 4. Create atespace
log "Creating ate-demo-counter atespace …"
$KA create atespace ate-demo-counter 2>/dev/null || log "  (atespace already exists)"

# 5. Create ActorTemplate (using s3:// for rustfs storage)
log "Creating counter ActorTemplate …"
$KA create actor-template -f - <<EOF
metadata:
  atespace: ate-demo-counter
  name: counter
workerSelector:
  matchLabels:
    workload: counter
containers:
- name: counter
  image: ${COUNTER_IMAGE}
  command: ["/ko-app/counter"]
  args: ["--extra-port=9090"]
  wakeupProbe:
    httpGet:
      path: /readyz
      port: 80
  volumeMounts:
  - name: data
    mountPath: /home/counter
resources:
  limits:
  - name: cpu
    quantity: "1"
  - name: memory
    quantity: 512Mi
snapshotConfig:
  onPause: SNAPSHOT_CONTENT_SCOPE_FULL
  onCommit: SNAPSHOT_CONTENT_SCOPE_FULL
  storageLocation: s3://ate-snapshots/ate-demo-counter/
sandboxConfig:
  sandboxClass: SANDBOX_CLASS_GVISOR
  configName: gvisor-default
volumes:
- name: data
  durableDir: {}
EOF

log "Waiting for golden snapshot to be ready (this may take 2–5 min) …"
for i in $(seq 1 60); do
  status=$($KA get actor-template counter -a ate-demo-counter -o json 2>/dev/null \
    | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('status',{}).get('state',''))" 2>/dev/null || true)
  if [[ "$status" == "READY" ]]; then
    log "  ✓ Template is READY."
    break
  fi
  echo "  … status=${status:-unknown} (${i}/60)"
  sleep 10
done

log ""
log "=== Counter demo is deployed. ==="
log ""
log "Next steps — run these in a separate terminal:"
log ""
log "  # 1. Port-forward the router"
log "  kubectl --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT \\"
log "    port-forward -n ate-system svc/atenet-router 8000:80"
log ""
log "  # 2. Create an actor"
log "  kubectl ate --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT \\"
log "    create actor my-counter-1 -a ate-demo-counter --template counter"
log ""
log "  # 3. Increment the counter (actor starts automatically on first request)"
log "  curl -X POST -H 'ate-target-actor: ate-demo-counter/my-counter-1' http://localhost:8000"
log ""
log "  # 4. Check actor state"
log "  kubectl ate --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT \\"
log "    get actor my-counter-1 -a ate-demo-counter"
log ""
log "  # 5. Suspend the actor (checkpoint to rustfs/S3)"
log "  kubectl ate --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT \\"
log "    suspend actor my-counter-1 -a ate-demo-counter"
log ""
log "  # 6. Resume by sending another request — counter continues from checkpoint"
log "  curl -X POST -H 'ate-target-actor: ate-demo-counter/my-counter-1' http://localhost:8000"
log ""
log "  # 7. Clean up"
log "  kubectl ate --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT \\"
log "    delete actor my-counter-1 -a ate-demo-counter"
log "  kubectl --kubeconfig $SHOOT_KC --context $KUBECTL_CONTEXT \\"
log "    delete namespace ate-demo-counter"
