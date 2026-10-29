#!/usr/bin/env bash
# Builds the server with `moon build --target native --release` and copies the
# resulting executable to bin/conduit. Runs as a normal user; idempotent.
#
# MOON_TOOLCHAIN_ROOT = read-only SDK from install.sh
#   (default /opt/moonbit-challenge/toolchains/moon-0.1.20261023).
# MOON_HOME = writable per-user cache; defaults to ./.moon-home inside this
#   directory (owned by the build user). moon resolves tools from
#   MOON_TOOLCHAIN_ROOT/bin while writing registry/cache under MOON_HOME.
set -euo pipefail
if [ "${BACKEND:-}" = "wasip3" ]; then exec bash "$(dirname "$0")/wasip3/build.sh" server; fi
cd "$(dirname "$0")"

SDK_VERSION=0.1.20261023
COMPILER=0.10.17+d971670cd
SDK="${MOON_TOOLCHAIN_ROOT:-/opt/moonbit-challenge/toolchains/moon-0.1.20261023}"
MOON="$SDK/bin/moon"
if [ ! -x "$MOON" ] || [ ! -x "$SDK/bin/moonc" ]; then
  echo "moonbit toolchain not found at $SDK; run install.sh first" >&2
  exit 1
fi
export MOON_TOOLCHAIN_ROOT="$SDK"
export PATH="$SDK/bin:$PATH"
export MOON_HOME="${MOON_HOME:-$PWD/.moon-home}"
mkdir -p "$MOON_HOME"

# Fail before fetching if either the SDK or the compiler does not match the
# exact pin.
sdk_out="$("$MOON" version 2>/dev/null || true)"
cc_out="$("$SDK/bin/moonc" -v 2>/dev/null || true)"
if ! printf '%s' "$sdk_out" | grep -qF "$SDK_VERSION"; then
  echo "wrong moon SDK at $SDK (need $SDK_VERSION, got: $sdk_out)" >&2
  exit 1
fi
if ! printf '%s' "$cc_out" | grep -qF "$COMPILER"; then
  echo "wrong compiler at $SDK (need $COMPILER, got: $cc_out)" >&2
  exit 1
fi

case "${BACKEND:-native}" in
  native) ;;
  *) echo "BACKEND must be 'native' or 'wasip3', got '$BACKEND'" >&2; exit 2 ;;
esac

# Update the registry index/symbols (deps are fetched lazily during
# `moon build`).
. ./moon-update.sh
moon_update "$MOON"

"$MOON" build --target native --release

mkdir -p bin
cp _build/native/release/build/conduit.exe bin/conduit
chmod +x bin/conduit
echo "built bin/conduit (native, $("$SDK/bin/moonc" -v | awk '{print $1}'))"
