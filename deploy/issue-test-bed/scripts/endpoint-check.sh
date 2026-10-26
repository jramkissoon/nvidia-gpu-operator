#!/usr/bin/env bash
# Check how the operator currently deployed handles a kubelet-plugin
# HTTP_ENDPOINT override, for the review comments on #3029 that its validation
# rejects working configurations:
#
#   dra_driver.go:152: a port-only comparison rejects metrics endpoints that
#     share a port on different addresses.
#   dra_driver.go:94:  the literal text of HTTP_ENDPOINT is parsed, so a $(VAR)
#     reference the kubelet would expand is rejected as nonnumeric.
#
# Deploys an overlay and reports one of three outcomes:
#
#   accepted:  the DaemonSet renders the override, both containers stay ready
#              with no restarts across two liveness periods, each container
#              logs its metrics server on the address it effectively binds, and
#              GET /metrics answers 200 there, checked from inside the pod
#              (port-forward only reaches 127.0.0.1). The plugin's startup
#              flag dump is printed too: it shows the value the kubelet handed
#              over, after any $(VAR) expansion.
#   rejected:  the GPUCluster gets ReconcileFailed for this overlay's endpoint
#              (REJECTED_RE); the reason is printed, since a build may reject
#              the right spec for the wrong reason.
#   collided:  the DaemonSet renders but a container restarts, i.e. the kernel
#              refused the second bind. This is the real-world symptom of a
#              collision the operator failed to catch.
#
# OVERLAY picks the case; each one sets the rendered env values (GPUS_EP,
# CD_EP), the addresses the plugin binds after expansion (GPUS_ADDR, CD_ADDR,
# equal to the rendered value unless it holds a reference) and METRICS_PORT.
# (PORT is taken by common.sh for the healthcheck scripts.)
#
#   compute-domains-metrics-distinct-hosts (default): 127.0.0.1:9090 and
#     127.0.0.2:9090. Release operator: accepted. Builds up to 3a8c81adf:
#     rejected. Fixed in f19b7c552.
#   gpus-metrics-host-vs-healthcheck: gpus metrics on 127.0.0.1:51515 against
#     the compute-domains wildcard health service. Release operator: collided.
#     PR builds: rejected, which a host-aware fix must preserve.
#   gpus-http-endpoint-expansion: METRICS_PORT=9090 then
#     HTTP_ENDPOINT=:$(METRICS_PORT). Release operator: accepted on :9090.
#     Builds up to f19b7c552: rejected as nonnumeric, the regression.
#   gpus-http-endpoint-expansion-collision: HTTP_ENDPOINT=:$(HEALTHCHECK_PORT),
#     which expands to the gpus health port. Release operator: collided.
#     Must stay rejected after the fix, ideally with "both resolve to 51516".
#
# EXPECT (accepted, the default, rejected or collided) sets which outcome exits
# 0. Deploy compute-domains-enabled first when the previous overlay already
# carried these endpoints, or a stale render reads as accepted.
# Evidence is saved under proof/endpoint-check-<timestamp>/.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
OVERLAY="${OVERLAY:-compute-domains-metrics-distinct-hosts}"
EXPECT="${EXPECT:-accepted}"
# Single quotes keep the $(...) references literal: they are for the kubelet.
case "$OVERLAY" in
  compute-domains-metrics-distinct-hosts)
    GPUS_EP="${GPUS_EP:-127.0.0.1:9090}"; CD_EP="${CD_EP:-127.0.0.2:9090}"; METRICS_PORT="${METRICS_PORT:-9090}" ;;
  gpus-metrics-host-vs-healthcheck)
    GPUS_EP="${GPUS_EP:-127.0.0.1:51515}"; CD_EP="${CD_EP:-}"; METRICS_PORT="${METRICS_PORT:-51515}" ;;
  gpus-http-endpoint-expansion)
    GPUS_EP="${GPUS_EP:-:\$(METRICS_PORT)}"; GPUS_ADDR="${GPUS_ADDR:-:9090}"; CD_EP="${CD_EP:-}"; METRICS_PORT="${METRICS_PORT:-9090}" ;;
  gpus-http-endpoint-expansion-collision)
    GPUS_EP="${GPUS_EP:-:\$(HEALTHCHECK_PORT)}"; GPUS_ADDR="${GPUS_ADDR:-:51516}"; CD_EP="${CD_EP:-}"; METRICS_PORT="${METRICS_PORT:-51516}" ;;
  *) : "${GPUS_EP:?set GPUS_EP for overlay $OVERLAY}" "${METRICS_PORT:?set METRICS_PORT for overlay $OVERLAY}"; CD_EP="${CD_EP:-}" ;;
esac
GPUS_ADDR="${GPUS_ADDR:-$GPUS_EP}"; CD_ADDR="${CD_ADDR:-$CD_EP}"
# A rejection this overlay can cause: the collision on its port, or the
# parse errors of builds that reject the literal text of HTTP_ENDPOINT.
REJECTED_RE="ReconcileFailed.*(both resolve to $METRICS_PORT|must use a numeric port|is not a host:port address)"
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
metrics_status() { # metrics_status <host:port>; an empty host means 127.0.0.1
  local pod host port; pod=$(newest_plugin_pod); host=${1%:*}; port=${1##*:}
  "${KUBECTL[@]}" -n "$NS" exec "$pod" -c gpus -- bash -c \
    "exec 3<>/dev/tcp/${host:-127.0.0.1}/$port && printf 'GET /metrics HTTP/1.0\r\nHost: x\r\n\r\n' >&3 && head -1 <&3" 2>/dev/null \
    | tr -d '\r' || echo "no connection"
}
# The httpEndpoint line of a container's startup flag dump: the value the
# kubelet handed over, after $(VAR) expansion.
flags_endpoint() { # flags_endpoint <container>
  local out line
  out=$("${KUBECTL[@]}" -n "$NS" logs "$(newest_plugin_pod)" -c "$1" 2>/dev/null || true)
  line=$(grep -m1 'httpEndpoint:' <<<"$out" | sed 's/^[[:space:]]*//') || line="(no httpEndpoint flag line)"
  echo "$line"
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
[ "$GPUS_ADDR" != "$GPUS_EP" ] && echo "gpus HTTP_ENDPOINT should expand to $GPUS_ADDR"
make -C "$TESTBED" deploy OVERLAY="$OVERLAY" >/dev/null

deadline=$(( $(date +%s) + TIMEOUT )); outcome=""
while (( $(date +%s) < deadline )); do
  if gpucluster_conditions | grep -Eq "$REJECTED_RE"; then outcome=rejected; break; fi
  if rendered; then outcome=rendered; break; fi
  sleep 3
done

echo "GPUCluster conditions:"; gpucluster_conditions
echo "rendered HTTP_ENDPOINT: gpus=$(ds_endpoint gpus) compute-domains=$(ds_endpoint compute-domains)"
dir="${PROOF_DIR:-$TESTBED/proof/endpoint-check-$(date +%Y%m%dT%H%M%S)}"

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
      PROOF_DIR="$dir" save_proof endpoint-check "$(newest_plugin_pod)" >/dev/null
    else
      wait_for "$TIMEOUT" "GPUCluster ready" '[ "$(gpucluster_state)" = ready ]'
      gpus_log=$(metrics_log_line gpus); cd_log=$(metrics_log_line compute-domains)
      gpus_flags=$(flags_endpoint gpus)
      gpus_http=$(metrics_status "$GPUS_ADDR")
      cd_http=""; [ -n "$CD_ADDR" ] && cd_http=$(metrics_status "$CD_ADDR")
      echo "gpus flags:          $gpus_flags"
      echo "gpus log:            $gpus_log"
      echo "compute-domains log: $cd_log"
      echo "GET $GPUS_ADDR/metrics -> $gpus_http"
      [ -n "$CD_ADDR" ] && echo "GET $CD_ADDR/metrics -> $cd_http"
      ok=1
      [[ "$gpus_http" == *" 200 "* ]] || ok=0
      [ -z "$CD_ADDR" ] || [[ "$cd_http" == *" 200 "* ]] || ok=0
      [[ "$gpus_log" == *"endpoint=\"$GPUS_ADDR\""* ]] || ok=0
      [ -z "$CD_ADDR" ] || [[ "$cd_log" == *"endpoint=\"$CD_ADDR\""* ]] || ok=0
      [[ "$gpus_flags" == *"\"$GPUS_ADDR\""* ]] || ok=0
      [ "$ok" = 1 ] || { echo "FAIL: rendered and stable, but metrics are not served on the configured addresses" >&2; exit 1; }
      outcome=accepted
      PROOF_DIR="$dir" save_proof endpoint-check "$(newest_plugin_pod)" >/dev/null
    fi
    ;;
  rejected)
    reason=$(gpucluster_conditions | grep -oE 'both resolve to [0-9]+|must use a numeric port|is not a host:port address' | head -1)
    echo "rejected for: $reason"
    PROOF_DIR="$dir" save_proof endpoint-check "" >/dev/null ;;
  *)
    echo "FAIL: neither rendered nor rejected within ${TIMEOUT}s" >&2; exit 1 ;;
esac
{
  echo "HTTP_ENDPOINT override check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image: $(operator_image)"
  echo "overlay:        $OVERLAY (gpus $GPUS_EP${CD_EP:+, compute-domains $CD_EP}; port $METRICS_PORT)"
  [ "$GPUS_ADDR" != "$GPUS_EP" ] && echo "expands to:     gpus $GPUS_ADDR"
  echo "outcome:        $outcome (expected $EXPECT)"
  [ "$outcome" = rejected ] && echo "rejected for:   $reason"
  echo "rendered:       gpus=$(ds_endpoint gpus) compute-domains=$(ds_endpoint compute-domains)"
  echo "containers:     $(pod_container_status)"
  [ "$outcome" = collided ] && echo "bind error:     $bind_err"
  if [ "$outcome" = accepted ]; then
    echo "metrics:        $GPUS_ADDR -> $gpus_http${CD_ADDR:+; $CD_ADDR -> $cd_http}"
    echo "gpus flags:     $gpus_flags"
    echo "gpus log:       $gpus_log"; echo "cd log:         $cd_log"
  fi
  echo "conditions:"; gpucluster_conditions
} > "$dir/summary.txt"
echo "proof saved under $dir"

echo
echo "OUTCOME: $outcome on $(operator_image) (expected $EXPECT)"
[ "$outcome" = "$EXPECT" ]
