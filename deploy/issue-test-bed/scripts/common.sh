# Shared helpers for the issue #2979 test-bed scripts. Source, do not run.
set -euo pipefail

TESTBED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$TESTBED/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-issue-2979}"
NS="${NS:-gpu-operator}"
DS="nvidia-dra-driver-kubelet-plugin"
PORT="${PORT:-51516}"   # the gpus default: setting computeDomains to it is the single-field collision
KUBECTL=(kubectl --context "kind-${CLUSTER_NAME}")

log() { printf '\n==> %s\n' "$*"; }

# wait_for <seconds> <description> <expression>: poll until the shell expression
# succeeds. The expression is a single-quoted string evaluated on every
# iteration, so command substitutions inside it are re-run each time; an
# unquoted $(...) argument would be expanded once, before the loop starts.
wait_for() {
  local deadline=$(( $(date +%s) + $1 )) what=$2 expr=$3
  until eval "$expr"; do
    if (( $(date +%s) >= deadline )); then echo "timed out waiting for: $what" >&2; return 1; fi
    sleep 5
  done
}

operator_image() {
  "${KUBECTL[@]}" -n "$NS" get deploy gpu-operator -o jsonpath='{.spec.template.spec.containers[0].image}'
}

ds_containers() {
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null
}

# HEALTHCHECK_PORT of each kubelet-plugin container, space separated.
ds_ports() {
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.env[?(@.name=="HEALTHCHECK_PORT")].value} {end}' 2>/dev/null
}

ds_generation() {
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" -o jsonpath='{.metadata.generation}' 2>/dev/null
}

gpucluster_conditions() {
  "${KUBECTL[@]}" get gpucluster gpu-cluster \
    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}'
}

# deploy_overlay <name>: apply an overlay and wait until the DaemonSet carries
# both kubelet-plugin containers. Every GPUCluster state the scripts need is an
# overlay, so no script patches the cluster directly; server-side apply from
# one manager also removes fields the previous overlay set.
deploy_overlay() {
  log "Deploying overlay $1"
  make -C "$TESTBED" mock-imex >/dev/null
  make -C "$TESTBED" deploy OVERLAY="$1" >/dev/null
  wait_for 180 "DaemonSet with both containers" '[ "$(ds_containers)" = "gpus compute-domains" ]'
  echo "containers: $(ds_containers)   HEALTHCHECK_PORT: $(ds_ports)"
}

newest_plugin_pod() {
  "${KUBECTL[@]}" -n "$NS" get pods -l app="$DS" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null
}

# "<name>=<ready>/<restarts> ..." for each container of the newest plugin pod.
pod_container_status() {
  local pod; pod=$(newest_plugin_pod) || return 1
  "${KUBECTL[@]}" -n "$NS" get pod "$pod" \
    -o jsonpath='{range .status.containerStatuses[*]}{.name}={.ready}/{.restartCount} {end}' 2>/dev/null
}

# startup and liveness gRPC probe ports per container, from the live pod spec.
pod_probe_ports() {
  local pod; pod=$(newest_plugin_pod) || return 1
  "${KUBECTL[@]}" -n "$NS" get pod "$pod" \
    -o jsonpath='{range .spec.containers[*]}{.name}: startup={.startupProbe.grpc.port} liveness={.livenessProbe.grpc.port}{"\n"}{end}'
}

# True when both kubelet-plugin containers of the newest pod report ready.
both_ready() {
  local pod; pod=$(newest_plugin_pod) || return 1
  local c
  for c in gpus compute-domains; do
    [ "$("${KUBECTL[@]}" -n "$NS" get pod "$pod" \
        -o jsonpath="{.status.containerStatuses[?(@.name==\"$c\")].ready}" 2>/dev/null)" = true ] || return 1
  done
}

# save_proof <name> <pod>: write the evidence for this run under proof/<name>-<timestamp>/
# and echo the directory. Files are plain text so they can be attached to or quoted
# in the PR. Set PROOF_DIR to choose the location.
save_proof() {
  local name=$1 pod=$2
  local dir="${PROOF_DIR:-$TESTBED/proof/$name-$(date +%Y%m%dT%H%M%S)}"
  mkdir -p "$dir"
  operator_image > "$dir/operator-image.txt"; echo >> "$dir/operator-image.txt"
  "${KUBECTL[@]}" get gpucluster gpu-cluster -o yaml > "$dir/gpucluster.yaml"
  gpucluster_conditions > "$dir/gpucluster-conditions.txt"
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" -o yaml > "$dir/daemonset.yaml"
  ds_ports > "$dir/daemonset-healthcheck-ports.txt"; echo >> "$dir/daemonset-healthcheck-ports.txt"
  if [ -n "$pod" ]; then
    "${KUBECTL[@]}" -n "$NS" describe pod "$pod" > "$dir/pod-describe.txt"
    for c in gpus compute-domains; do
      "${KUBECTL[@]}" -n "$NS" logs "$pod" -c "$c" --tail=-1 > "$dir/$c.log" 2>&1 || true
      "${KUBECTL[@]}" -n "$NS" logs "$pod" -c "$c" --previous --tail=-1 > "$dir/$c.previous.log" 2>&1 || true
    done
  fi
  echo "$dir"
}
