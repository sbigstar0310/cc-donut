#!/usr/bin/env bash
# Run test/smoke.sh inside a clean Linux container — catches GNU-vs-BSD issues
# that pass on macOS (e.g. the `stat -f` regression that silently froze the
# quota cache on Linux).
#
#   test/docker.sh              # debian:stable-slim
#   test/docker.sh alpine:3.20  # any image with bash+python3+coreutils
set -euo pipefail
IMAGE="${1:-debian:stable-slim}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "$IMAGE" in
  alpine*) INSTALL='apk add --no-cache bash python3 coreutils >/dev/null' ;;
  *)       INSTALL='apt-get -qq update >/dev/null && apt-get -qq install -y python3 >/dev/null' ;;
esac

exec docker run --rm -v "$ROOT":/ccd:ro -w /ccd "$IMAGE" /bin/sh -c "
  $INSTALL
  echo \"# \$(cat /etc/os-release 2>/dev/null | grep -m1 PRETTY_NAME || uname -a)\"
  bash --version | head -1
  bash /ccd/test/smoke.sh
"
