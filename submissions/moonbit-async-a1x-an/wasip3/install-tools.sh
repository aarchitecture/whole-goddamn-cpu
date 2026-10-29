#!/usr/bin/env bash
# WASI 0.3 toolchain installer: official release archives only, cached
# hash verification, fresh mktemp extraction, no rm -rf, no unexpected
# prefix overwrite. Layout: $WASI03_TOOLS/bin/{wit-bindgen,wasm-tools}
# and $WASI03_TOOLS/bin/wasmtime-50/wasmtime. Full release bundles retain
# their licenses; verified archives remain in dl/.
set -euo pipefail
cd "$(dirname "$0")"
WASI03_TOOLS="${WASI03_TOOLS:-/opt/moonbit-challenge/wasi03-tools}"
DL="$WASI03_TOOLS/dl"
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *) echo "WASI tools require Linux x86_64" >&2; exit 1 ;;
esac

# name|filename|sha256|url|topdir_in_archive
SPEC=$(cat <<'SPECS'
wit-bindgen|wit-bindgen.tgz|bf4efe883ab70d34a4740253911dda20caf895d58a003af58369506b04684cbe|https://github.com/bytecodealliance/wit-bindgen/releases/download/v0.63.0/wit-bindgen-0.63.0-x86_64-linux.tar.gz|wit-bindgen-0.63.0-x86_64-linux
wasm-tools|wasm-tools.tgz|655b8df67d54c3ef9b52fc237c4e94bbfbb5f5f43825245cb0940a7002a9ed65|https://github.com/bytecodealliance/wasm-tools/releases/download/v1.262.0/wasm-tools-1.262.0-x86_64-linux.tar.gz|wasm-tools-1.262.0-x86_64-linux
wasmtime|wasmtime.txz|77c19ee0437991f9ac7837b9c269d9c7076744f85dad263fea5214cc2723c7ff|https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasmtime-v50.0.0-x86_64-linux.tar.xz|wasmtime-v50.0.0-x86_64-linux
SPECS
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need tar; need sha256sum; need python3; need xz; need curl

fetch() { # fetch into dl with hash verify; reuse verified cache
  local file="$1" sha="$2" url="$3"
  if [ ! -e "$DL/$file" ]; then
    local tmp
    tmp="$(mktemp "$DL/download.XXXXXX")"
    curl --noproxy '*' -fL --retry 2 -o "$tmp" "$url"
    echo "$sha  $tmp" | sha256sum -c -
    mv -n "$tmp" "$DL/$file"
  fi
  echo "$sha  $DL/$file" | sha256sum -c - || {
    echo "invalid cache: $DL/$file; refusing to overwrite" >&2; exit 1;
  }
}

verify() {
  local name="$1" binary="$2" pattern
  case "$name" in
    wit-bindgen) pattern='^wit-bindgen(-cli)? 0\.63\.0([[:space:]]|$)' ;;
    wasm-tools) pattern='^wasm-tools 1\.262\.0([[:space:]]|$)' ;;
    wasmtime) pattern='^wasmtime 50\.0\.0([[:space:]]|$)' ;;
  esac
  if [ ! -x "$binary" ] || ! "$binary" --version | grep -Eq "$pattern"; then
    echo "missing or incompatible pinned tool: $binary" >&2
    return 1
  fi
}

echo "installing WASI 0.3 toolchain to $WASI03_TOOLS"
mkdir -p "$DL" "$WASI03_TOOLS/bin"
while IFS='|' read -r name file sha url top; do
  [ -z "$name" ] && continue
  case "$name" in
    wasmtime) binary="$WASI03_TOOLS/bin/wasmtime-50/wasmtime" ;;
    *) binary="$WASI03_TOOLS/bin/$name" ;;
  esac
  if [ -e "$binary" ]; then
    verify "$name" "$binary"
    continue
  fi
  if [ -e "$WASI03_TOOLS/$top" ]; then
    echo "unexpected existing bundle: $WASI03_TOOLS/$top" >&2
    exit 1
  fi
  fetch "$file" "$sha" "$url"
  tmp="$(mktemp -d "$WASI03_TOOLS/extract.XXXXXX")"
  tar -C "$tmp" -xf "$DL/$file"
  [ -x "$tmp/$top/$name" ] || {
    echo "archive $file lacks expected executable" >&2; exit 1;
  }
  mv -T -n "$tmp/$top" "$WASI03_TOOLS/$top"
  [ ! -e "$tmp/$top" ] || { echo "bundle destination already exists" >&2; exit 1; }
  rmdir "$tmp"
  chmod -R a+rX "$WASI03_TOOLS/$top"
  mkdir -p "$(dirname "$binary")"
  cp -n "$WASI03_TOOLS/$top/$name" "$binary"
  verify "$name" "$binary"
done <<< "$SPEC"
echo "done: $WASI03_TOOLS"
