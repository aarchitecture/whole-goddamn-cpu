#!/usr/bin/env bash
# Runs once as root on Ubuntu 24.04. Installs the pinned MoonBit toolchain
# (moonc v0.10.17+d971670cd / SDK moon 0.1.20261023) into a fresh versioned
# prefix (default /opt/moonbit-challenge/toolchains/moon-0.1.20261023,
# overridable via MOON_TOOLCHAIN_ROOT), world-readable for the build user.
# The exact compiler-version URLs are used; "latest" is never consulted.
# sha256 pins were verified against these URLs.
#
# MOON_TOOLCHAIN_ROOT = the read-only SDK (bin/include/lib/share).
# MOON_HOME = the per-user writable cache (registry/index/tmp); the
# installer uses its own throwaway MOON_HOME while bundling core.
# Never overwrites/chowns an existing non-empty directory.
set -euo pipefail

SDK_VERSION=0.1.20261023
COMPILER=0.10.17+d971670cd
SDK="${MOON_TOOLCHAIN_ROOT:-/opt/moonbit-challenge/toolchains/moon-0.1.20261023}"
MOONBIT_URL="https://cli.moonbitlang.com/binaries/0.10.17%2Bd971670cd/moonbit-linux-x86_64.tar.gz"
CORE_URL="https://cli.moonbitlang.com/cores/core-0.10.17%2Bd971670cd.tar.gz"
MOONBIT_TGZ_SHA256=d0a96eaf91c77cfcdd7b7df75390c5a1a95d0b8a328b1a5ed6fee050cfbf8d50
CORE_TGZ_SHA256=2d837ecbef5933c09726d63682a7695123d622e6aee13525fbc98c4b49433714
BUNDLE_MARKER="lib/core/_build/native/release/bundle/core.core"

# C toolchain (required for native builds), OpenSSL headers and helpers.
apt-get update -q
apt-get install -y -q build-essential pkg-config libssl-dev curl ca-certificates
if [ "${BACKEND:-}" = "wasip3" ]; then
  apt-get install -y -q python3 xz-utils
  bash "$(dirname "$0")/wasip3/install-tools.sh"
fi

# Fast path: exact SDK + compiler + bundled native core already present.
if [ -x "$SDK/bin/moon" ] && [ -x "$SDK/bin/moonc" ] && \
   [ -s "$SDK/$BUNDLE_MARKER" ]; then
  TMP_MH0="$(mktemp -d /tmp/moon-home-check.XXXXXX)"
  sdk_out="$(PATH="$SDK/bin:$PATH" MOON_HOME="$TMP_MH0" MOON_TOOLCHAIN_ROOT="$SDK" "$SDK/bin/moon" version 2>/dev/null || true)"
  cc_out="$(PATH="$SDK/bin:$PATH" MOON_HOME="$TMP_MH0" MOON_TOOLCHAIN_ROOT="$SDK" "$SDK/bin/moonc" -v 2>/dev/null || true)"
  rm -rf "$TMP_MH0"
  if printf '%s' "$sdk_out" | grep -qF "$SDK_VERSION" && \
     printf '%s' "$cc_out" | grep -qF "$COMPILER"; then
    echo "moonbit $COMPILER already installed at $SDK"
    exit 0
  fi
fi

# Any other non-empty target directory is refused outright.
if [ -d "$SDK" ] && [ -n "$(ls -A "$SDK" 2>/dev/null)" ]; then
  echo "error: $SDK is not empty; refusing to install over existing content" >&2
  exit 1
fi

TMPD="$(mktemp -d /tmp/moonbit-install.XXXXXX)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

curl -fsSL -o "$TMPD/moonbit.tar.gz" "$MOONBIT_URL"
echo "$MOONBIT_TGZ_SHA256  $TMPD/moonbit.tar.gz" | sha256sum -c -
mkdir -p "$SDK"
tar -xzf "$TMPD/moonbit.tar.gz" -C "$SDK"

curl -fsSL -o "$TMPD/core.tar.gz" "$CORE_URL"
echo "$CORE_TGZ_SHA256  $TMPD/core.tar.gz" | sha256sum -c -
mkdir -p "$SDK/lib"
tar -xzf "$TMPD/core.tar.gz" -C "$SDK/lib"

chmod -R a+rX "$SDK"
chmod +x "$SDK"/bin/* "$SDK"/bin/internal/* 2>/dev/null || true

# Bundle core for the native backend (mirrors the official installer).
# MOON_TOOLCHAIN_ROOT points at the read-only SDK; bundling needs a writable
# cache dir, so use a throwaway MOON_HOME.
TMP_MH="$(mktemp -d /tmp/moon-home.XXXXXX)"
export PATH="$SDK/bin:$PATH"
export MOON_TOOLCHAIN_ROOT="$SDK"
export MOON_HOME="$TMP_MH"
"$SDK/bin/moon" -C "$SDK/lib/core" bundle --warn-list -a --all
rm -rf "$TMP_MH"
trap - EXIT
rm -rf "$TMPD"

[ -s "$SDK/$BUNDLE_MARKER" ] || {
  echo "error: bundled core artifact missing at $SDK/$BUNDLE_MARKER" >&2
  exit 1
}
"$SDK/bin/moon" version --all
