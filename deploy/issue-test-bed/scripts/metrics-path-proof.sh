#!/usr/bin/env bash
# Prove the METRICS_PATH review follow-up on PR #3029 on the operator currently
# deployed (review comment: a metrics listener disabled with an empty
# METRICS_PATH must not count as a port collision):
#
#   good:      compute-domains-metrics-disabled empties METRICS_PATH in both
#              containers and moves their healthchecks onto the metrics ports
#              (gpus 8080, computeDomains 8081). The operator must accept and
#              render it, both health services must bind the freed ports and
#              pass their probes, and the GPUCluster must reach ready. A
#              container whose metrics listener still started would lose the
#              bind and crash-loop, so this also proves the empty value reaches
#              the plugin over the template's METRICS_PATH=/metrics.
#   bad:       gpus-metrics-port-collision puts the gpus healthcheck on 8080
#              with metrics left on. The operator must still reject it and leave
#              the healthy DaemonSet untouched.
#   recovery:  compute-domains-metrics-disabled again; ready again.
#
# Against an operator without the follow-up the good run is rejected with
# "both resolve to 8080" and this script exits 1. Evidence is saved under
# proof/metrics-path-proof-<timestamp>/{good,bad}/.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
GOOD="compute-domains-metrics-disabled"; GOOD_GPUS_PORT=8080; GOOD_CD_PORT=8081
BAD="gpus-metrics-port-collision"
TIMEOUT="${TIMEOUT:-120}"
READY_TIMEOUT="${READY_TIMEOUT:-420}"
ROOT="${PROOF_DIR:-$TESTBED/proof/metrics-path-proof-$(date +%Y%m%dT%H%M%S)}"

gpucluster_state() { "${KUBECTL[@]}" get gpucluster gpu-cluster -o jsonpath='{.status.state}'; }
rejected_on() { gpucluster_conditions | grep -q "ReconcileFailed.*both resolve to $1"; }

# Every METRICS_PATH entry per container in the rendered DaemonSet, in order;
# the last one is what the plugin sees.
ds_metrics_paths() {
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}:{range .env[?(@.name=="METRICS_PATH")]} "{.value}"{end}{"\n"}{end}'
}

log "Operator under test: $(operator_image)"

# ---------------------------------------------------------------------- good
make -C "$TESTBED" mock-imex >/dev/null
log "Deploying overlay $GOOD"
make -C "$TESTBED" deploy OVERLAY="$GOOD" >/dev/null
deadline=$(( $(date +%s) + READY_TIMEOUT ))
until [ "$(ds_ports)" = "$GOOD_GPUS_PORT $GOOD_CD_PORT " ]; do
  if rejected_on "$GOOD_GPUS_PORT" || rejected_on "$GOOD_CD_PORT"; then
    echo "GPUCluster conditions:"; gpucluster_conditions
    echo "FAIL: operator rejected a spec whose metrics listeners are disabled; this build has no METRICS_PATH follow-up." >&2
    exit 1
  fi
  (( $(date +%s) < deadline )) || { echo "FAIL: DaemonSet not rendered on $GOOD_GPUS_PORT/$GOOD_CD_PORT; ports: $(ds_ports)" >&2; gpucluster_conditions >&2; exit 1; }
  sleep 3
done
wait_for "$READY_TIMEOUT" "both containers ready" 'both_ready'
wait_for "$READY_TIMEOUT" "GPUCluster ready" '[ "$(gpucluster_state)" = ready ]'
# Liveness probes run every 30s; hold for two periods and require no restarts.
before=$(pod_container_status); sleep 65; after=$(pod_container_status)
[ "$before" = "$after" ] || { echo "FAIL: containers restarted while healthy: before='$before' after='$after'" >&2; exit 1; }
good_gen=$(ds_generation); good_ports=$(ds_ports)
echo "DaemonSet:    generation=$good_gen HEALTHCHECK_PORT=$good_ports"
echo "METRICS_PATH:"; ds_metrics_paths | sed 's/^/  /'
echo "probes:";       pod_probe_ports | sed 's/^/  /'
echo "containers:   $after (ready/restarts, unchanged over 65s)"
echo "GPUCluster:   $(gpucluster_state)"
dir=$(PROOF_DIR="$ROOT/good" save_proof good "$(newest_plugin_pod)")
{
  echo "PR #3029 METRICS_PATH follow-up, good config, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image: $(operator_image)"
  echo "overlay:        $GOOD (metrics off; healthchecks gpus=$GOOD_GPUS_PORT computeDomains=$GOOD_CD_PORT)"
  echo "daemonset:      generation=$good_gen HEALTHCHECK_PORT=$good_ports"
  echo "METRICS_PATH entries (last wins):"; ds_metrics_paths | sed 's/^/  /'
  echo "probes:"; pod_probe_ports | sed 's/^/  /'
  echo "containers:     $after (ready/restarts, unchanged over 65s)"
  echo "gpucluster:     ready"
} > "$dir/summary.txt"
echo "proof saved under $dir"
echo "GOOD CONFIG VERIFIED: metrics-disabled spec accepted; healthchecks bound the metrics ports and passed their probes."

# ----------------------------------------------------------------------- bad
log "Deploying overlay $BAD"
make -C "$TESTBED" deploy OVERLAY="$BAD" >/dev/null
deadline=$(( $(date +%s) + TIMEOUT )); outcome=""
while (( $(date +%s) < deadline )); do
  if rejected_on 8080; then outcome=rejected; break; fi
  if [ "$(ds_generation)" != "$good_gen" ]; then outcome=rerendered; break; fi
  sleep 3
done
echo "GPUCluster conditions:"; gpucluster_conditions
echo "DaemonSet:  generation=$(ds_generation) HEALTHCHECK_PORT=$(ds_ports)"
echo "containers: $(pod_container_status)"
case "$outcome" in
  rejected)
    gpucluster_conditions | grep -q "the gpus container metrics endpoint" \
      || { echo "FAIL: rejected, but not for the gpus metrics endpoint" >&2; exit 1; }
    if [ "$(ds_generation)" != "$good_gen" ] || [ "$(ds_ports)" != "$good_ports" ]; then
      echo "FAIL: spec was rejected but the DaemonSet changed anyway" >&2; exit 1
    fi
    both_ready || { echo "FAIL: containers lost readiness during rejection" >&2; exit 1; }
    ;;
  rerendered) echo "FAIL: operator re-rendered the DaemonSet for a colliding spec." >&2; exit 1 ;;
  *)          echo "FAIL: neither rejection nor re-render within ${TIMEOUT}s." >&2; exit 1 ;;
esac
dir=$(PROOF_DIR="$ROOT/bad" save_proof bad "$(newest_plugin_pod)")
{
  echo "PR #3029 METRICS_PATH follow-up, bad config, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image:   $(operator_image)"
  echo "overlay:          $BAD (gpus healthcheck 8080, gpus metrics on)"
  echo "daemonset before: generation=$good_gen HEALTHCHECK_PORT=$good_ports"
  echo "daemonset after:  generation=$(ds_generation) HEALTHCHECK_PORT=$(ds_ports)"
  echo "containers:       $(pod_container_status)"
  echo "rejection:"; gpucluster_conditions | grep ReconcileFailed
} > "$dir/summary.txt"
echo "proof saved under $dir"
echo "BAD CONFIG VERIFIED: metrics-port collision still rejected; healthy DaemonSet untouched."

# ------------------------------------------------------------------ recovery
log "Deploying overlay $GOOD"
make -C "$TESTBED" deploy OVERLAY="$GOOD" >/dev/null
wait_for "$READY_TIMEOUT" "GPUCluster ready after recovery" '[ "$(gpucluster_state)" = ready ]'
echo "GPUCluster conditions:"; gpucluster_conditions
echo
echo "METRICS_PATH FOLLOW-UP VERIFIED on $(operator_image)"
echo "evidence: $ROOT/{good,bad}"
echo "The cluster is left on overlay $GOOD."
