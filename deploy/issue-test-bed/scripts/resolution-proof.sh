#!/usr/bin/env bash
# Prove the fix for gpu-operator issue #2979 on the operator currently
# deployed, as two overlays against the same build:
#
#   good:      compute-domains-good-ports sets non-default, distinct ports. The
#              operator must render them, both containers must bind and pass
#              their startup and liveness probes, and the GPUCluster must reach
#              ready. This shows the operator still works as intended.
#   bad:       compute-domains-port-collision sets the computeDomains port to
#              the gpus default. The operator must reject the spec with a
#              ReconcileFailed condition, leave the healthy DaemonSet untouched,
#              and keep both containers ready.
#   recovery:  compute-domains-good-ports again; the GPUCluster must return
#              to ready.
#
# Against an operator without the fix the bad run re-renders the DaemonSet
# with equal ports instead, and this script exits 1. Each run saves its
# evidence under proof/resolution-proof-<timestamp>/{good,bad}/.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
GOOD="compute-domains-good-ports"; GOOD_GPUS_PORT=52000; GOOD_CD_PORT=52001
BAD="compute-domains-port-collision"   # computeDomains port = $PORT (51516)
TIMEOUT="${TIMEOUT:-120}"             # bad run: wait for rejection or re-render
READY_TIMEOUT="${READY_TIMEOUT:-420}" # good run: rollout + plugin start + probes
ROOT="${PROOF_DIR:-$TESTBED/proof/resolution-proof-$(date +%Y%m%dT%H%M%S)}"

gpucluster_state() { "${KUBECTL[@]}" get gpucluster gpu-cluster -o jsonpath='{.status.state}'; }
wait_healthy() { # wait_healthy <what>
  wait_for "$READY_TIMEOUT" "DaemonSet on ports $GOOD_GPUS_PORT/$GOOD_CD_PORT" '[ "$(ds_ports)" = "$GOOD_GPUS_PORT $GOOD_CD_PORT " ]'
  wait_for "$READY_TIMEOUT" "both containers ready ($1)" 'both_ready'
  wait_for "$READY_TIMEOUT" "GPUCluster ready ($1)" '[ "$(gpucluster_state)" = ready ]'
}

log "Operator under test: $(operator_image)"

# ---------------------------------------------------------------------- good
deploy_overlay "$GOOD"
wait_healthy "good config"
# Liveness probes run every 30s; hold for two periods and require no restarts.
before=$(pod_container_status); sleep 65; after=$(pod_container_status)
[ "$before" = "$after" ] || { echo "FAIL: containers restarted while healthy: before='$before' after='$after'" >&2; exit 1; }
good_gen=$(ds_generation); good_ports=$(ds_ports)
echo "DaemonSet:  generation=$good_gen HEALTHCHECK_PORT=$good_ports"
echo "probes:";   pod_probe_ports | sed 's/^/  /'
echo "containers: $after (ready/restarts, unchanged over 65s)"
echo "GPUCluster: $(gpucluster_state)"
dir=$(PROOF_DIR="$ROOT/good" save_proof good "$(newest_plugin_pod)")
{
  echo "gpu-operator issue #2979, good config, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image: $(operator_image)"
  echo "overlay:        $GOOD (gpus=$GOOD_GPUS_PORT computeDomains=$GOOD_CD_PORT)"
  echo "daemonset:      generation=$good_gen HEALTHCHECK_PORT=$good_ports"
  echo "probes:"; pod_probe_ports | sed 's/^/  /'
  echo "containers:     $after (ready/restarts, unchanged over 65s)"
  echo "gpucluster:     ready"
} > "$dir/summary.txt"
echo "proof saved under $dir"
echo "GOOD CONFIG VERIFIED: distinct ports rendered, both health services bound and probed."

# ----------------------------------------------------------------------- bad
# The collision overlay drops the gpus port override, so the gpus side resolves
# to its default; the operator must reject before re-rendering anything.
log "Deploying overlay $BAD"
make -C "$TESTBED" deploy OVERLAY="$BAD" >/dev/null
rejected()   { gpucluster_conditions | grep -q "ReconcileFailed.*both resolve to $PORT"; }
rerendered() { [ "$(ds_ports)" = "$PORT $PORT " ]; }
deadline=$(( $(date +%s) + TIMEOUT )); outcome=""
while (( $(date +%s) < deadline )); do
  if rejected;   then outcome=rejected;   break; fi
  if rerendered; then outcome=rerendered; break; fi
  sleep 3
done
echo "GPUCluster conditions:"; gpucluster_conditions
echo "DaemonSet:  generation=$(ds_generation) HEALTHCHECK_PORT=$(ds_ports)"
echo "containers: $(pod_container_status)"
case "$outcome" in
  rejected)
    if [ "$(ds_generation)" != "$good_gen" ] || [ "$(ds_ports)" != "$good_ports" ]; then
      echo "FAIL: spec was rejected but the DaemonSet changed anyway" >&2; exit 1
    fi
    both_ready || { echo "FAIL: containers lost readiness during rejection" >&2; exit 1; }
    ;;
  rerendered) echo "FAIL: operator rendered both containers on port $PORT; this build has no fix." >&2; exit 1 ;;
  *)          echo "FAIL: neither rejection nor re-render within ${TIMEOUT}s." >&2; exit 1 ;;
esac
dir=$(PROOF_DIR="$ROOT/bad" save_proof bad "$(newest_plugin_pod)")
{
  echo "gpu-operator issue #2979, bad config, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image:   $(operator_image)"
  echo "overlay:          $BAD (computeDomains healthcheck port $PORT, the gpus default)"
  echo "daemonset before: generation=$good_gen HEALTHCHECK_PORT=$good_ports"
  echo "daemonset after:  generation=$(ds_generation) HEALTHCHECK_PORT=$(ds_ports)"
  echo "containers:       $(pod_container_status)"
  echo "rejection:"; gpucluster_conditions | grep ReconcileFailed
} > "$dir/summary.txt"
echo "proof saved under $dir"
echo "BAD CONFIG VERIFIED: colliding spec rejected; healthy DaemonSet untouched; containers stayed ready."

# ------------------------------------------------------------------ recovery
deploy_overlay "$GOOD"
wait_for "$READY_TIMEOUT" "GPUCluster ready after recovery" '[ "$(gpucluster_state)" = ready ]'
echo "GPUCluster conditions:"; gpucluster_conditions
echo
echo "FIX VERIFIED on $(operator_image)"
echo "evidence: $ROOT/{good,bad}"
echo "The cluster is left on overlay $GOOD."
