#!/usr/bin/env bash
# Direct WASI 0.3 launcher: ONE wasmtime serve process hosting
# WASI_INSTANCES pooled component instances; each instance owns one PG
# connection and runs on the host Tokio runtime (WORKERS threads).
# No nginx/docker/host adapter.
set -euo pipefail
cd "$(dirname "$0")"
WASI03_TOOLS="${WASI03_TOOLS:-/opt/moonbit-challenge/wasi03-tools}"
WASMTIME="${WASMTIME:-$WASI03_TOOLS/bin/wasmtime-50/wasmtime}"
[ -x "$WASMTIME" ] || { echo "wasmtime not found at $WASMTIME" >&2; exit 1; }
"$WASMTIME" --version | grep -Eq '^wasmtime 50\.0\.0([[:space:]]|$)' || {
  echo "wasmtime 50.0.0 required at $WASMTIME" >&2; exit 1; }
: "${DATABASE_URL:?export DATABASE_URL}"
: "${JWT_SECRET:?export JWT_SECRET}"
parse_num() { # bounded ASCII decimal, leading zeros ok
  case "$2" in ''|*[!0-9]*) return 1;; esac
  [ ${#2} -gt 5 ] && return 1
  echo "$((10#$2))"
}
HOST="${HOST:-127.0.0.1}"
PORT="$(parse_num p "${PORT:-3000}")" || { echo "PORT must be numeric" >&2; exit 1; }
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "PORT must be 1-65535" >&2; exit 1; }
NP=$(nproc 2>/dev/null || echo 8); [ "$NP" -gt 8 ] && NP=8
WORKERS="$(parse_num w "${WORKERS:-$NP}")" || { echo "WORKERS must be numeric" >&2; exit 1; }
[ "$WORKERS" -ge 1 ] && [ "$WORKERS" -le 80 ] || { echo "WORKERS must be 1..80" >&2; exit 1; }
WASI_INSTANCES="$(parse_num i "${WASI_INSTANCES:-80}")" || { echo "WASI_INSTANCES must be numeric" >&2; exit 1; }
[ "$WASI_INSTANCES" -ge 1 ] && [ "$WASI_INSTANCES" -le 95 ] || { echo "WASI_INSTANCES must be 1..95" >&2; exit 1; }
if [ -n "${DB_POOL_SIZE:-}" ] && [ "$DB_POOL_SIZE" != "1" ]; then
  echo "DB_POOL_SIZE must be 1 under WASI (one conn per instance)" >&2; exit 1
fi
WASM="$(cd .. 2>/dev/null && pwd)/bin/conduit.component.wasm"
[ -f "$WASM" ] || WASM="$(dirname "$0")/../bin/conduit.component.wasm"
[ -f "$WASM" ] || { echo "component missing: $WASM - run build.sh first" >&2; exit 1; }
# health check URL host: wildcard -> loopback, IPv6 bracketed
case "$HOST" in
  0.0.0.0) CURL_HOST=127.0.0.1 ;;
  ::|::1) CURL_HOST="[::1]" ;;
  *:*)    CURL_HOST="[$HOST]" ;;
  *)      CURL_HOST="$HOST" ;;
esac
case "$HOST" in
  *:*) ADDR="[$HOST]:$PORT" ;;
  *) ADDR="$HOST:$PORT" ;;
esac
# host-side Tokio thread count (host export, not guest env)
export TOKIO_WORKER_THREADS="$WORKERS"
# expose guest env vars by name only (never values on argv)
echo "wasip3 conduit: wasmtime serve on $HOST:$PORT workers=$WORKERS instances=$WASI_INSTANCES"
"$WASMTIME" serve \
  -Scli -Sp3 -Sinherit-network=y -W component-model-async=y \
  --addr "$ADDR" \
  --max-instance-concurrent-reuse-count 1 \
  --max-concurrent-requests "$WASI_INSTANCES" \
  --max-concurrent-connections 100000 \
  --max-instance-reuse-count 9223372036854775807 \
  --idle-instance-timeout 3600s \
  -O pooling-allocator=y \
  -O pooling-total-component-instances="$WASI_INSTANCES" \
  -O pooling-max-memory-size=67108864 \
  --env DATABASE_URL \
  --env JWT_SECRET \
  "$WASM" &
CHILD=$!
cleanup() {
  local st=$?
  trap - INT TERM EXIT
  kill "$CHILD" 2>/dev/null || true
  wait "$CHILD" 2>/dev/null || true
  return "$st"
}
trap 'exit 0' TERM
trap 'exit 130' INT
trap 'cleanup' EXIT
# startup health check: real elapsed deadline, bounded curl calls
START=$(date +%s)
while :; do
  NOW=$(date +%s); [ $((NOW - START)) -ge 60 ] && break
  kill -0 "$CHILD" 2>/dev/null || { echo "wasmtime exited during startup" >&2; exit 1; }
  if curl --noproxy '*' --connect-timeout 1 --max-time 2 -sf -o /dev/null \
      "http://$CURL_HOST:$PORT/api/tags" 2>/dev/null; then
    wait "$CHILD"
    exit $?
  fi
  sleep 1
done
echo "startup check failed after 60s" >&2
exit 1
