#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04.
set -euo pipefail

ODIN_VERSION="dev-2026-08"
ODIN_SHA256="d858c0a182bb28d7b04b04dbb8aed592a9c96c84e4400ee917c74b45848a4d87"
ODIN_URL="https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz"
ODIN_TOP="odin-linux-amd64-nightly+2026-08-06"

apt-get update -q
apt-get install -y -q \
  ca-certificates \
  clang \
  curl \
  libc6-dev \
  libcrypt-dev \
  libpq-dev \
  lld

curl -fsSLo /tmp/odin.tar.gz "$ODIN_URL"
echo "$ODIN_SHA256  /tmp/odin.tar.gz" | sha256sum -c -
rm -rf "/usr/local/$ODIN_TOP" /usr/local/odin
tar -C /usr/local -xzf /tmp/odin.tar.gz
rm /tmp/odin.tar.gz
mv "/usr/local/$ODIN_TOP" /usr/local/odin
ln -sf /usr/local/odin/odin /usr/local/bin/odin

/usr/local/odin/odin version
