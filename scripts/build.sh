#!/usr/bin/env bash
# Build the PathOps Dex image locally with the upstream Dockerfile of the
# patched source tree. Never pushes.
#
# usage: scripts/build.sh
#   IMAGE          local image reference   (default: pathops-dex:local)
#   IMAGE_VERSION  version baked into Dex  (default: <upstream>-pathops.dev)
#   SKIP_PREPARE=1 reuse an already prepared tree
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PATHOPS_DEX_WORKDIR:-$ROOT/.work}/dex"
VERSION=$(tr -d '[:space:]' < "$ROOT/UPSTREAM_VERSION")
IMAGE=${IMAGE:-pathops-dex:local}
IMAGE_VERSION=${IMAGE_VERSION:-${VERSION}-pathops.dev}

[ "${SKIP_PREPARE:-0}" = "1" ] || "$ROOT/scripts/prepare-source.sh"

labels=()
while IFS= read -r label; do
  labels+=(--label "$label")
done < <("$ROOT/scripts/metadata.sh" labels "$IMAGE_VERSION")

docker build --build-arg VERSION="$IMAGE_VERSION" "${labels[@]}" -t "$IMAGE" "$SRC"
echo "build: $IMAGE (Dex version $IMAGE_VERSION)"
