#!/usr/bin/env bash
# Build the gpu-operator from this worktree, load it into the kind cluster,
# point the test bed at it, and deploy the compute-domains-enabled overlay.
#
# The image choice is the kustomize component at components/operator-image,
# maintained with `kustomize edit set image`. The tag carries the commit so a
# rebuild changes the Deployment and rolls the operator; a fixed tag would
# leave the old container running. Pass --release to switch back to the
# pinned release image instead.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
COMPONENT="$TESTBED/kustomize/components/operator-image"
RELEASE_VERSION="${RELEASE_VERSION:-v26.7.1}"

if [ "${1:-}" = "--release" ]; then
  image="nvcr.io/nvidia/gpu-operator:$RELEASE_VERSION"
  log "Switching back to the release image $image"
else
  tag="issue-2979-$(git -C "$REPO" describe --match="" --dirty --always)"
  image="localhost/gpu-operator:$tag"
  log "Building $image from $REPO"
  make -C "$REPO" build-image IMAGE_NAME=localhost/gpu-operator VERSION="$tag"
  log "Loading the image into kind cluster $CLUSTER_NAME"
  kind load docker-image "$image" --name "$CLUSTER_NAME"
fi
(cd "$COMPONENT" && kustomize edit set image "nvcr.io/nvidia/gpu-operator=$image")
echo "component now:"; sed 's/^/  /' "$COMPONENT/kustomization.yaml"

log "Deploying the compute-domains-enabled overlay with $image"
make -C "$TESTBED" deploy OVERLAY=compute-domains-enabled >/dev/null
wait_for 300 "operator Deployment on $image" '[ "$(operator_image)" = "$image" ]'
"${KUBECTL[@]}" -n "$NS" rollout status deploy/gpu-operator --timeout=300s
echo "operator image: $(operator_image)"
