#!/usr/bin/env bash
# Run every check of the issue #2979 test bed against the operator currently
# deployed, which is expected to carry the fix (make post-fix-images). Each
# step is one of the existing scripts with the expectation a fixed operator
# must meet; the steps run in order, a failure does not stop the rest, and the
# exit status is the number of failed steps.
#
#   resolution-proof        issue #2979: distinct ports healthy, the single-field
#                           collision rejected, recovery
#   metrics-path-proof      review follow-up: an empty METRICS_PATH frees 8080/8081
#   http-endpoint-check     Devin review: a moved metrics endpoint is accepted,
#                           and still rejected when it lands on a health port
#   endpoint-check x6       kvalliyurnatt's three comments: distinct hosts,
#                           $(VAR) expansion, service names, each with its
#                           accepted case and its collision case
#
# Every step keeps its own proof directory; this script also writes each step's
# output and a summary under proof/e2e-<timestamp>/. The cluster is left on the
# last overlay deployed. Against the release operator most steps fail by
# design: use the individual targets with EXPECT=... to reproduce the comments.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ROOT="${PROOF_DIR:-$TESTBED/proof/e2e-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$ROOT"

# reset: put the cluster on the neutral overlay so a step that cannot tell a
# stale render from its own (http-endpoint-check) starts from the defaults.
reset() {
  log "Resetting to compute-domains-enabled"
  make -C "$TESTBED" deploy OVERLAY=compute-domains-enabled >/dev/null
  wait_for 420 "default DaemonSet" '[ "$(ds_ports)" = "51516 51515 " ]'
  wait_for 420 "GPUCluster ready after the reset" \
    '[ "$("${KUBECTL[@]}" get gpucluster gpu-cluster -o jsonpath="{.status.state}")" = ready ]'
}

# step <name> <env...> -- <command...>: run one check, capture its output, record
# pass or fail. Environment assignments precede the command.
declare -a NAMES RESULTS SECONDS_TAKEN
step() {
  local name=$1; shift
  local -a env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done; shift
  log "STEP $name: ${env[*]} $*"
  local start=$(date +%s) rc=0
  env "${env[@]}" "$@" > "$ROOT/$name.log" 2>&1 || rc=$?
  local took=$(( $(date +%s) - start ))
  tail -3 "$ROOT/$name.log" | sed 's/^/    /'
  NAMES+=("$name"); SECONDS_TAKEN+=("$took")
  if [ "$rc" = 0 ]; then RESULTS+=(PASS); echo "    -> PASS (${took}s)"
  else RESULTS+=("FAIL rc=$rc"); echo "    -> FAIL rc=$rc (${took}s), see $ROOT/$name.log"; fi
}

log "e2e for issue #2979 on $(operator_image)"
make -C "$TESTBED" mock-imex >/dev/null
S="$TESTBED/scripts"

step resolution-proof                 -- "$S/resolution-proof.sh"
step metrics-path-proof               -- "$S/metrics-path-proof.sh"
reset
step http-endpoint-override           EXPECT=accepted -- "$S/http-endpoint-check.sh"
reset
step http-endpoint-collision          OVERLAY=gpus-http-endpoint-collision EXPECT=rejected -- "$S/http-endpoint-check.sh"
step distinct-hosts                   OVERLAY=compute-domains-metrics-distinct-hosts EXPECT=accepted -- "$S/endpoint-check.sh"
step host-vs-healthcheck              OVERLAY=gpus-metrics-host-vs-healthcheck EXPECT=rejected -- "$S/endpoint-check.sh"
step env-expansion                    OVERLAY=gpus-http-endpoint-expansion EXPECT=accepted -- "$S/endpoint-check.sh"
step env-expansion-collision          OVERLAY=gpus-http-endpoint-expansion-collision EXPECT=rejected -- "$S/endpoint-check.sh"
step named-port                       OVERLAY=gpus-http-endpoint-named-port EXPECT=accepted -- "$S/endpoint-check.sh"
step named-port-collision             OVERLAY=gpus-http-endpoint-named-port-collision EXPECT=rejected -- "$S/endpoint-check.sh"

failed=0
{
  echo "issue #2979 e2e, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "operator image: $(operator_image)"
  echo
  for i in "${!NAMES[@]}"; do
    printf '  %-26s %-10s %4ss\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${SECONDS_TAKEN[$i]}"
    [[ "${RESULTS[$i]}" == PASS ]] || failed=$((failed + 1))
  done
  echo
  echo "$failed of ${#NAMES[@]} steps failed"
} | tee "$ROOT/summary.txt"
echo "logs and summary under $ROOT"
exit "$failed"
