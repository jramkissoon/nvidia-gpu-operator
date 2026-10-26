#!/usr/bin/env bash
# Reproduce gpu-operator issue #2979 and print the proof.
#
# Deploys the compute-domains-port-collision overlay, whose GPUCluster sets the
# computeDomains healthcheck port to the gpus default. An operator without the
# fix renders both containers on that port; they share the pod's network
# namespace, so the second bind fails with EADDRINUSE and that container
# crash-loops.
#
# Exit 0 when the crash was observed, 1 otherwise. The cluster is left in the
# reproduced state so it can be inspected; redeploy another overlay to leave it.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
OVERLAY="compute-domains-port-collision"
TIMEOUT="${TIMEOUT:-420}"

log "Operator under test: $(operator_image)"
deploy_overlay "$OVERLAY"

log "Waiting for the operator to render both containers on port $PORT"
wait_for 180 "DaemonSet re-render" '[ "$(ds_ports)" = "$PORT $PORT " ]' \
  || { echo "DaemonSet was not re-rendered with equal ports; ports: $(ds_ports)" >&2; gpucluster_conditions >&2; exit 1; }
echo "DaemonSet HEALTHCHECK_PORT per container: $(ds_ports)"

log "Waiting up to ${TIMEOUT}s for a container to fail its bind"
found="" line="" pod=""
deadline=$(( $(date +%s) + TIMEOUT ))
while (( $(date +%s) < deadline )); do
  pod=$(newest_plugin_pod || true)
  for c in gpus compute-domains; do
    for prev in "" "--previous"; do
      # shellcheck disable=SC2086
      if line=$("${KUBECTL[@]}" -n "$NS" logs "$pod" -c "$c" $prev --tail=200 2>/dev/null \
                | grep -m1 "address already in use"); then
        found="$c"; break 3
      fi
    done
  done
  sleep 5
done

log "Proof"
if [ -z "$found" ]; then
  echo "no 'address already in use' log line within ${TIMEOUT}s" >&2
  "${KUBECTL[@]}" -n "$NS" get pods -l app="$DS" -o wide >&2
  exit 1
fi
echo "operator image:    $(operator_image)"
echo "overlay:           $OVERLAY"
echo "pod:               $pod"
echo "losing container:  $found"
echo "log line:          $line"
echo "container statuses: $(pod_container_status) (ready/restarts)"
echo "GPUCluster conditions:"; gpucluster_conditions

dir=$(save_proof issue-replication "$pod")
{
  echo "gpu-operator issue #2979 reproduction, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image:   $(operator_image)"
  echo "overlay:          $OVERLAY (computeDomains healthcheck port $PORT, the gpus default)"
  echo "daemonset ports:  $(ds_ports)"
  echo "pod:              $pod"
  echo "losing container: $found"
  echo "log line:         $line"
} > "$dir/summary.txt"
echo
echo "proof saved under $dir:"; ls -1 "$dir" | sed 's/^/  /'
echo "  (the bind failure is in $found.log or $found.previous.log)"
echo
echo "ISSUE REPRODUCED: both containers rendered on port $PORT and '$found' failed to bind."
echo "Leave this state with: make deploy OVERLAY=compute-domains-enabled"
