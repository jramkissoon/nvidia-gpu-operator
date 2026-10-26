#!/usr/bin/env bash
# Check how the operator currently deployed handles an HTTP_ENDPOINT override in
# kubeletPlugin.env (Devin review on #3029: rejecting the name breaks existing
# GPUClusters that moved the metrics listener).
#
# Deploys compute-domains-http-endpoint-override (gpus metrics on :9090) and
# reports one of two outcomes:
#
#   accepted:  the DaemonSet renders the override, both containers become ready,
#              and the gpus container serves Prometheus metrics on 9090, read
#              through a port-forward, and no longer on 8080.
#   rejected:  the GPUCluster gets ReconcileFailed for this overlay's
#              HTTP_ENDPOINT (see REJECTED_RE).
#
# EXPECT (accepted, the default, or rejected) sets which outcome exits 0.
# OVERLAY swaps in gpus-http-endpoint-collision, which must be rejected for the
# port clash even with HTTP_ENDPOINT allowed. Run that one from a state whose
# DaemonSet does not already carry :9090, or a stale render reads as accepted.
# Evidence is saved under proof/http-endpoint-check-<timestamp>/.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
OVERLAY="${OVERLAY:-compute-domains-http-endpoint-override}"
EXPECT="${EXPECT:-accepted}"
# The GPUCluster status carries no observedGeneration, so a condition left by the
# previous overlay looks current until the operator reconciles again. Only count
# a rejection this overlay can cause: the reserved-name error of builds that
# forbid HTTP_ENDPOINT, plus the 9090 clash for the collision overlay.
REJECTED_RE='ReconcileFailed.*must not set HTTP_ENDPOINT'
if [ "$OVERLAY" = gpus-http-endpoint-collision ]; then
  REJECTED_RE='ReconcileFailed.*(must not set HTTP_ENDPOINT|HTTP_ENDPOINT ":9090".*both resolve to 9090)'
fi
ENDPOINT=":9090"; METRICS_PORT=9090
TIMEOUT="${TIMEOUT:-420}"
LOCAL_PORT="${LOCAL_PORT:-19090}"

gpucluster_state() { "${KUBECTL[@]}" get gpucluster gpu-cluster -o jsonpath='{.status.state}'; }
# Every HTTP_ENDPOINT entry of the gpus container, in order; the last one wins.
gpus_endpoints() {
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" \
    -o jsonpath='{range .spec.template.spec.containers[?(@.name=="gpus")].env[?(@.name=="HTTP_ENDPOINT")]}"{.value}" {end}'
}
# HTTP status of GET /metrics on a container port of the newest plugin pod.
metrics_status() { # metrics_status <container port>
  local pod pf code; pod=$(newest_plugin_pod)
  "${KUBECTL[@]}" -n "$NS" port-forward "pod/$pod" "$LOCAL_PORT:$1" >/dev/null 2>&1 & pf=$!
  sleep 3
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$LOCAL_PORT/metrics" || true)
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null || true
  echo "${code:-000}"
}

log "Operator under test: $(operator_image)"
make -C "$TESTBED" mock-imex >/dev/null
log "Deploying overlay $OVERLAY"
make -C "$TESTBED" deploy OVERLAY="$OVERLAY" >/dev/null

deadline=$(( $(date +%s) + TIMEOUT )); outcome=""
while (( $(date +%s) < deadline )); do
  if gpucluster_conditions | grep -Eq "$REJECTED_RE"; then outcome=rejected; break; fi
  if [[ "$(gpus_endpoints)" == *"\"$ENDPOINT\" " ]]; then outcome=rendered; break; fi
  sleep 3
done

echo "GPUCluster conditions:"; gpucluster_conditions
echo "gpus HTTP_ENDPOINT entries (last wins): $(gpus_endpoints)"
dir="${PROOF_DIR:-$TESTBED/proof/http-endpoint-check-$(date +%Y%m%dT%H%M%S)}"

case "$outcome" in
  rendered)
    wait_for "$TIMEOUT" "both containers ready" 'both_ready'
    wait_for "$TIMEOUT" "GPUCluster ready" '[ "$(gpucluster_state)" = ready ]'
    on_new=$(metrics_status "$METRICS_PORT"); on_old=$(metrics_status 8080)
    status=$(pod_container_status)
    echo "metrics GET :$METRICS_PORT/metrics -> $on_new   :8080/metrics -> $on_old"
    echo "containers: $status (ready/restarts)"
    [ "$on_new" = 200 ] && [ "$on_old" != 200 ] \
      || { echo "FAIL: override rendered but metrics are not served on $METRICS_PORT only" >&2; exit 1; }
    outcome=accepted
    PROOF_DIR="$dir" save_proof http-endpoint-check "$(newest_plugin_pod)" >/dev/null
    ;;
  rejected)
    PROOF_DIR="$dir" save_proof http-endpoint-check "" >/dev/null ;;
  *)
    echo "FAIL: neither rendered nor rejected within ${TIMEOUT}s" >&2; exit 1 ;;
esac
{
  echo "HTTP_ENDPOINT override check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image: $(operator_image)"
  echo "overlay:        $OVERLAY (gpus HTTP_ENDPOINT $ENDPOINT)"
  echo "outcome:        $outcome (expected $EXPECT)"
  echo "gpus HTTP_ENDPOINT entries: $(gpus_endpoints)"
  [ "$outcome" = accepted ] && echo "metrics:        :$METRICS_PORT -> $on_new, :8080 -> $on_old; containers $status"
  echo "conditions:"; gpucluster_conditions
} > "$dir/summary.txt"
echo "proof saved under $dir"

echo
echo "OUTCOME: $outcome on $(operator_image) (expected $EXPECT)"
[ "$outcome" = "$EXPECT" ]
