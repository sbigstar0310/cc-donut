#!/usr/bin/env bash
# Run test/smoke.sh inside a clean Linux container — catches GNU-vs-BSD issues
# that pass on macOS (e.g. the `stat -f` regression that silently froze the
# quota cache on Linux).
#
#   test/docker.sh              # debian:stable-slim
#   test/docker.sh alpine:3.20  # any image with bash+python3+coreutils
#   CCD_DOCKER_EMULATE=1 test/docker.sh alpine:3.20  # a foreign-arch image, on purpose
set -euo pipefail
IMAGE="${1:-debian:stable-slim}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "$IMAGE" in
  alpine*) INSTALL='apk add --no-cache bash python3 coreutils >/dev/null' ;;
  # procps is not optional: without pgrep/pkill the statusline's single-flight,
  # watchdog and cleanup assertions all count zero processes and pass vacuously.
  *)       INSTALL='apt-get -qq update >/dev/null && apt-get -qq install -y python3 procps >/dev/null' ;;
esac

# A tag is one name for several per-arch images and the last pull wins: one
# `pull --platform` left alpine amd64 on an arm64 Mac, and qemu's signal and
# timing failures were carried as "known" for five days (#70). An uncached image
# needs no check, and an unreadable answer only warns: this never blocks a gate.
if have=$(docker image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null); then
  want=$(docker version --format '{{.Server.Arch}}' 2>/dev/null) || want=
  if [ -z "$have" ] || [ -z "$want" ]; then
    echo "docker.sh: could not compare $IMAGE's architecture with this Docker's; running unchecked" >&2
  elif [ "$have" != "$want" ] && [ "${CCD_DOCKER_EMULATE:-}" != 1 ]; then
    cat >&2 <<EOF
docker.sh: $IMAGE is cached as $have, but this Docker runs $want.
  It would run under emulation, which breaks the signal and timing tests.
  Fix: docker pull --platform linux/$want $IMAGE
  Or run it emulated on purpose: CCD_DOCKER_EMULATE=1 $0 $IMAGE
EOF
    exit 1
  fi
fi

exec docker run --rm -v "$ROOT":/ccd:ro -w /ccd "$IMAGE" /bin/sh -c "
  $INSTALL
  echo \"# \$(cat /etc/os-release 2>/dev/null | grep -m1 PRETTY_NAME || uname -a)\"
  bash --version | head -1
  bash /ccd/test/smoke.sh
"
