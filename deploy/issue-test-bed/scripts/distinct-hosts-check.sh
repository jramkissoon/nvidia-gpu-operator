#!/usr/bin/env bash
# Check how the operator currently deployed handles metrics endpoints that share
# a port but bind different addresses (kvalliyurnatt's review of #3029,
# dra_driver.go:152: a port-only comparison falsely rejects them).
#
# Deploys an overlay and reports one of three outcomes:
#
#   accepted:  the DaemonSet renders the endpoints, both containers stay ready
#              with no restarts across two liveness periods, each container
#              logs its metrics server on the configured address, and GET
#              /metrics answers 200 on every specific address, checked from
#              inside the pod (port-forward only reaches 127.0.0.1).
#   rejected:  the GPUCluster gets ReconcileFailed with "both resolve to <port>".
#   collided:  the DaemonSet renders but a container restarts, i.e. the kernel
#              refused the second bind. This is the real-world symptom of a
#              collision the operator failed to catch.
#
# OVERLAY picks the case; GPUS_EP, CD_EP and METRICS_PORT must describe it
# (PORT is taken by common.sh for the healthcheck scripts):
#   compute-domains-metrics-distinct-hosts (default): 127.0.0.1:9090 and
#     127.0.0.2:9090. Release operator: accepted. PR build at 3a8c81adf:
#     rejected, which is the false positive the comment describes.
#   gpus-metrics-host-vs-healthcheck: gpus metrics on 127.0.0.1:51515 against
#     the compute-domains wildcard health service. Release operator: collided.
#     PR build: rejected, which a host-aware fix must preserve.
# EXPECT (accepted, the default, rejected or collided) sets which outcome exits
# 0. Deploy compute-domains-enabled first when the previous overlay already
# carried these endpoints, or a stale render reads as accepted.
# Evidence is saved under proof/distinct-hosts-check-<timestamp>/.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
OVERLAY="${OVERLAY:-compute-domains-metrics-distinct-hosts}"
EXPECT="${EXPECT:-accepted}"
case "$OVERLAY" in
  compute-domains-metrics-distinct-hosts)
    GPUS_EP="${GPUS_EP:-127.0.0.1:9090}"; CD_EP="${CD_EP:-127.0.0.2:9090}"; METRICS_PORT="${METRICS_PORT:-9090}" ;;
  gpus-metrics-host-vs-healthcheck)
    GPUS_EP="${GPUS_EP:-127.0.0.1:51515}"; CD_EP="${CD_EP:-}"; METRICS_PORT="${METRICS_PORT:-51515}" ;;
  *) : "${GPUS_EP:?set GPUS_EP for overlay $OVERLAY}" "${METRICS_PORT:?set METRICS_PORT for overlay $OVERLAY}"; CD_EP="${CD_EP:-}" ;;
esac
REJECTED_RE="ReconcileFailed.*both resolve to $METRICS_PORT"
TIMEOUT="${TIMEOUT:-420}"
HOLD="${HOLD:-65}"   # liveness probes run every 30s; two periods

gpucluster_state() { "${KUBECTL[@]}" get gpucluster gpu-cluster -o jsonpath='{.status.state}'; }
# Last HTTP_ENDPOINT entry of a container in the rendered DaemonSet; the kubelet
# keeps the last value for a duplicated name.
ds_endpoint() { # ds_endpoint <container>
  "${KUBECTL[@]}" -n "$NS" get ds "$DS" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$1\")].env[?(@.name==\"HTTP_ENDPOINT\")].value}" 2>/dev/null \
    | awk '{print $NF}'
}
rendered() {
  [ "$(ds_endpoint gpus)" = "$GPUS_EP" ] && { [ -z "$CD_EP" ] || [ "$(ds_endpoint compute-domains)" = "$CD_EP" ]; }
}
# HTTP status line of GET /metrics on host:port, dialed from inside the gpus
# container with bash's /dev/tcp. All containers share the pod network namespace,
# so this reaches the compute-domains listener too, and specific loopback
# addresses that kubectl port-forward cannot.
metrics_status() { # metrics_status <host:port>
  local pod; pod=$(newest_plugin_pod)
  "${KUBECTL[@]}" -n "$NS" exec "$pod" -c gpus -- bash -c \
    "exec 3<>/dev/tcp/${1%:*}/${1##*:} && printf 'GET /metrics HTTP/1.0\r\nHost: x\r\n\r\n' >&3 && head -1 <&3" 2>/dev/null \
    | tr -d '\r' || echo "no connection"
}
# The metrics server start line of a container, if it logged one. The log is
# captured first: grep -m1 closing the pipe early would trip pipefail and
# append the fallback to a found line.
metrics_log_line() { # metrics_log_line <container>
  local out line
  out=$("${KUBECTL[@]}" -n "$NS" logs "$(newest_plugin_pod)" -c "$1" 2>/dev/null || true)
  line=$(grep -m1 'Starting metrics HTTP server' <<<"$out") || line="(no metrics server start line)"
  echo "$line"
}
# The listen failure of whichever container lost the bind, from its previous
# instance's log (the health service fails first; a metrics server failure
# exits the process the same way).
bind_error_line() {
  local pod c out line; pod=$(newest_plugin_pod)
  for c in gpus compute-domains; do
    out=$("${KUBECTL[@]}" -n "$NS" logs "$pod" -c "$c" --previous 2>/dev/null || true)
    line=$(grep -m1 -E 'address already in use|listen on metrics endpoint' <<<"$out") && { echo "$c: $line"; return; }
  done
  echo "(no bind error found in previous logs)"
}
restarts_total() { pod_container_status | grep -oE '/[0-9]+' | tr -d / | paste -sd+ - | bc; }

log "Operator under test: $(operator_image)"
make -C "$TESTBED" mock-imex >/dev/null
log "Deploying overlay $OVERLAY (gpus HTTP_ENDPOINT $GPUS_EP${CD_EP:+, compute-domains HTTP_ENDPOINT $CD_EP})"
make -C "$TESTBED" deploy OVERLAY="$OVERLAY" >/dev/null

deadline=$(( $(date +%s) + TIMEOUT )); outcome=""
while (( $(date +%s) < deadline )); do
  if gpucluster_conditions | grep -Eq "$REJECTED_RE"; then outcome=rejected; break; fi
  if rendered; then outcome=rendered; break; fi
  sleep 3
done

echo "GPUCluster conditions:"; gpucluster_conditions
echo "rendered HTTP_ENDPOINT: gpus=$(ds_endpoint gpus) compute-domains=$(ds_endpoint compute-domains)"
dir="${PROOF_DIR:-$TESTBED/proof/distinct-hosts-check-$(date +%Y%m%dT%H%M%S)}"

case "$outcome" in
  rendered)
    # Wait for the new pod to exist, then hold: a lost bind shows up as a restart.
    wait_for "$TIMEOUT" "a plugin pod for the new render" '[ -n "$(newest_plugin_pod)" ]'
    sleep 20
    echo "holding ${HOLD}s (two liveness periods) to catch a lost bind as a restart..."
    before=$(pod_container_status); sleep "$HOLD"; after=$(pod_container_status)
    echo "containers: before='$before' after='$after' (ready/restarts over ${HOLD}s)"
    if [ "$before" != "$after" ] || [ "$(restarts_total)" -gt 0 ] || ! both_ready; then
      outcome=collided
      echo "gpus log:            $(metrics_log_line gpus)"
      echo "compute-domains log: $(metrics_log_line compute-domains)"
      bind_err=$(bind_error_line)
      echo "bind error:          $bind_err"
      PROOF_DIR="$dir" save_proof distinct-hosts-check "$(newest_plugin_pod)" >/dev/null
    else
      wait_for "$TIMEOUT" "GPUCluster ready" '[ "$(gpucluster_state)" = ready ]'
      gpus_log=$(metrics_log_line gpus); cd_log=$(metrics_log_line compute-domains)
      gpus_http=$(metrics_status "$GPUS_EP")
      cd_http=""; [ -n "$CD_EP" ] && cd_http=$(metrics_status "$CD_EP")
      echo "gpus log:            $gpus_log"
      echo "compute-domains log: $cd_log"
      echo "GET $GPUS_EP/metrics -> $gpus_http"
      [ -n "$CD_EP" ] && echo "GET $CD_EP/metrics -> $cd_http"
      ok=1
      [[ "$gpus_http" == *" 200 "* ]] || ok=0
      [ -z "$CD_EP" ] || [[ "$cd_http" == *" 200 "* ]] || ok=0
      [[ "$gpus_log" == *"endpoint=\"$GPUS_EP\""* ]] || ok=0
      [ -z "$CD_EP" ] || [[ "$cd_log" == *"endpoint=\"$CD_EP\""* ]] || ok=0
      [ "$ok" = 1 ] || { echo "FAIL: rendered and stable, but metrics are not served on the configured addresses" >&2; exit 1; }
      outcome=accepted
      PROOF_DIR="$dir" save_proof distinct-hosts-check "$(newest_plugin_pod)" >/dev/null
    fi
    ;;
  rejected)
    PROOF_DIR="$dir" save_proof distinct-hosts-check "" >/dev/null ;;
  *)
    echo "FAIL: neither rendered nor rejected within ${TIMEOUT}s" >&2; exit 1 ;;
esac
{
  echo "Distinct-hosts metrics check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image: $(operator_image)"
  echo "overlay:        $OVERLAY (gpus $GPUS_EP${CD_EP:+, compute-domains $CD_EP}; port $METRICS_PORT)"
  echo "outcome:        $outcome (expected $EXPECT)"
  echo "rendered:       gpus=$(ds_endpoint gpus) compute-domains=$(ds_endpoint compute-domains)"
  echo "containers:     $(pod_container_status)"
  [ "$outcome" = collided ] && echo "bind error:     $bind_err"
  if [ "$outcome" = accepted ]; then
    echo "metrics:        $GPUS_EP -> $gpus_http${CD_EP:+; $CD_EP -> $cd_http}"
    echo "gpus log:       $gpus_log"; echo "cd log:         $cd_log"
  fi
  echo "conditions:"; gpucluster_conditions
} > "$dir/summary.txt"
echo "proof saved under $dir"

echo
echo "OUTCOME: $outcome on $(operator_image) (expected $EXPECT)"
[ "$outcome" = "$EXPECT" ]
