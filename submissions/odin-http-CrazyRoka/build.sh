#!/usr/bin/env bash
# Builds the Odin Conduit server -> bin/conduit. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

ODIN=/usr/local/odin/odin
[ -x "$ODIN" ] || ODIN=odin

mkdir -p bin
"$ODIN" build src \
  -collection:lib=src/lib \
  -out:bin/conduit \
  -o:speed \
  -define:ODIN_NBIO_QUEUE_SIZE=4096
echo "built bin/conduit"
