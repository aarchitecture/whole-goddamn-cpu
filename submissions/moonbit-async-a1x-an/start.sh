#!/usr/bin/env bash
# Foreground supervisor: forks WORKERS copies of bin/conduit on the SAME
# HOST:PORT via SO_REUSEPORT. On any worker exit (unexpected or clean) it
# stops the remaining workers and exits nonzero; workers are never restarted.
# Config from caller: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional overrides: WORKERS (default min(nproc,8), range 1..47),
# DB_POOL_SIZE (per-worker connections for single statements and
# transactions, default 2, or 1 when that would exceed the budget) and
# DB_BATCH_CONNS (per-worker connections for batched reads, default 1).
# workers * (pool + batch) must stay <= 95.
set -euo pipefail
if [ "${BACKEND:-}" = "wasip3" ]; then exec bash "$(dirname "$0")/wasip3/start.sh"; fi
cd "$(dirname "$0")"
DIR="$(pwd)"

# Bounded decimal parser: ASCII digits only, <= 5 chars, no leading-zero
# octal, returns the number or fails.
parse_num() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -gt 5 ] && return 1
  # strip leading zeros to avoid octal interpretation
  local n=$((10#$1))
  [ "$n" -ge 0 ] || return 1
  echo "$n"
}

WORKERS="${WORKERS:-}"
if [ -z "$WORKERS" ]; then
  NPROC="$(nproc 2>/dev/null || echo 1)"
  WORKERS=$([ "$NPROC" -lt 8 ] && echo "$NPROC" || echo 8)
fi
if ! WORKERS_N="$(parse_num "$WORKERS")" || [ "$WORKERS_N" -lt 1 ] || [ "$WORKERS_N" -gt 47 ]; then
  echo "WORKERS must be an integer in 1..47, got '$WORKERS'" >&2
  exit 2
fi
WORKERS="$WORKERS_N"

DEFAULT_POOL=2
[ $((WORKERS * (DEFAULT_POOL + 1))) -gt 95 ] && DEFAULT_POOL=1
conns() { # name value-or-empty default
  local n
  if [ -z "$2" ]; then echo "$3"; return 0; fi
  if ! n="$(parse_num "$2")" || [ "$n" -lt 1 ] || [ "$n" -gt 95 ]; then
    echo "$1 must be an integer in 1..95, got '$2'" >&2
    return 1
  fi
  echo "$n"
}
POOL="$(conns DB_POOL_SIZE "${DB_POOL_SIZE:-}" "$DEFAULT_POOL")" || exit 2
BATCH="$(conns DB_BATCH_CONNS "${DB_BATCH_CONNS:-}" 1)" || exit 2
if [ $((WORKERS * (POOL + BATCH))) -gt 95 ]; then
  echo "WORKERS=$WORKERS * (DB_POOL_SIZE=$POOL + DB_BATCH_CONNS=$BATCH) exceeds total budget 95" >&2
  exit 2
fi
export DB_POOL_SIZE="$POOL" DB_BATCH_CONNS="$BATCH"

case "${BACKEND:-native}" in
  native) ;;
  *) echo "BACKEND must be 'native' or 'wasip3', got '$BACKEND'" >&2; exit 2 ;;
esac
CMD=("$DIR/bin/conduit")
[ -x "${CMD[0]}" ] || { echo "bin/conduit missing; run build.sh" >&2; exit 1; }

pids=()
signal=""
stop_workers() {
  for p in "${pids[@]}"; do
    kill "$p" 2>/dev/null || true
  done
}
trap 'signal=TERM; stop_workers' TERM
trap 'signal=INT; stop_workers' INT
trap stop_workers EXIT

HELPERS="${BCRYPT_HELPERS:-1}"
if ! HELPERS="$(parse_num "$HELPERS")" || [ "$HELPERS" -gt 8 ]; then
  echo "BCRYPT_HELPERS must be an integer in 0..8" >&2
  exit 2
fi
ADDRS=()
h=0
while [ "$h" -lt "$HELPERS" ]; do
  PORT_FILE="$(mktemp)"
  CONDUIT_BCRYPTD_PORT_FILE="$PORT_FILE" "${CMD[@]}" &
  pids+=("$!")
  for _ in $(seq 100); do
    [ -s "$PORT_FILE" ] && break
    kill -0 "$!" 2>/dev/null || break
    sleep 0.1
  done
  BCRYPTD_PORT="$(cat "$PORT_FILE")"
  rm -f "$PORT_FILE"
  [ -n "$BCRYPTD_PORT" ] || { echo "bcrypt helper did not start" >&2; exit 1; }
  ADDRS+=("127.0.0.1:$BCRYPTD_PORT")
  h=$((h + 1))
done

i=0
while [ "$i" -lt "$WORKERS" ]; do
  if [ "$HELPERS" -gt 0 ]; then
    CONDUIT_BCRYPTD_ADDR="${ADDRS[$((i % HELPERS))]}" "${CMD[@]}" &
  else
    "${CMD[@]}" &
  fi
  pids+=("$!")
  i=$((i + 1))
done
echo "started $WORKERS worker(s) on ${HOST:-127.0.0.1}:${PORT:-3000}, pool $POOL + batch $BATCH each, $HELPERS bcrypt helper(s)" >&2

# Foreground wait: first worker exit tears the rest down; any exit is an
# abnormal termination for a server, so the supervisor exits nonzero.
set +e
wait -n
status=$?
set -e
trap - TERM INT EXIT
if [ -n "$signal" ]; then
  echo "received SIG$signal; stopping workers" >&2
else
  echo "a worker exited (status $status); stopping remaining workers" >&2
fi
stop_workers
for p in "${pids[@]}"; do
  wait "$p" 2>/dev/null || true
done
case "$signal" in
  TERM) exit 0 ;;
  INT) exit 130 ;;
esac
exit $((status == 0 ? 1 : status))
