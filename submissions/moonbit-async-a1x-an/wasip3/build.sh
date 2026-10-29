#!/usr/bin/env bash
# Reproducible WASI 0.3 server or DB-probe component build.
# - copies current world.wit into staging every run
# - cold-fetches the six pinned WASI v0.3.2 WIT packages (cached)
# - regenerates bindings, installs handwritten facade+probe, builds core wasm,
#   componentizes, validates, lists imports
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
SRC="$(cd ../src && pwd)"

SDK="${MOON_TOOLCHAIN_ROOT:-/opt/moonbit-challenge/toolchains/moon-0.1.20261023}"
TOOLS="${WASI03_TOOLS:-/opt/moonbit-challenge/wasi03-tools}"
STAGE="${WASI03_STAGE:-${WASI03_DB_STAGE:-${XDG_CACHE_HOME:-$HOME/.cache}/conduit-wasip3}}"
WIT_DIR="$STAGE/wit-0.3.2"
MODE="${1:-server}"
case "$MODE" in
  server|dbprobe) ;;
  *) echo "build mode must be server or dbprobe" >&2; exit 2 ;;
esac
GEN="$STAGE/gen-$MODE"
if [ "$MODE" = "dbprobe" ]; then OUT="$STAGE/dbprobe.component.wasm"; else OUT="$STAGE/conduit.component.wasm"; fi
ARCHIVE="$STAGE/wasi-0.3.2.tar.gz"
WASI_URL="https://github.com/WebAssembly/WASI/archive/refs/tags/v0.3.2.tar.gz"

export MOON_TOOLCHAIN_ROOT="$SDK"
export PATH="$SDK/bin:$PATH"
export MOON_HOME="${MOON_HOME:-$STAGE/.moon-home}"

if ! "$SDK/bin/moon" version | grep -qF '0.1.20261023' ||
   ! "$SDK/bin/moonc" -v | grep -qF '0.10.17+d971670cd'; then
  echo "wrong MoonBit SDK/compiler; run install.sh" >&2
  exit 1
fi
for b in wit-bindgen wasm-tools; do [ -x "$TOOLS/bin/$b" ] || { echo "$b missing" >&2; exit 1; }; done

mkdir -p "$WIT_DIR" "$MOON_HOME"
cp world.wit "$WIT_DIR/world.wit"

if [ ! -d "$WIT_DIR/deps/http" ]; then
  [ -f "$ARCHIVE" ] || curl -fsSL -o "$ARCHIVE" "$WASI_URL"
  echo "55e01b36cd48fe39c2cb29943a40dc22b83b4564f09d8939f765445bc545d779  $ARCHIVE" |
    sha256sum -c -
  TMPX="$(mktemp -d "$STAGE/wasi-extract.XXXXXX")"
  tar xzf "$ARCHIVE" -C "$TMPX"
  for p in cli clocks random sockets filesystem http; do
    mkdir -p "$WIT_DIR/deps/$p"
    for f in "$TMPX/WASI-0.3.2/proposals/$p/wit"/*.wit; do cp "$f" "$WIT_DIR/deps/$p/"; done
  done
fi

"$TOOLS/bin/wit-bindgen" moonbit --world server --project-name conduit/wasip3 \
  --derive-show --derive-eq --derive-error --out-dir "$GEN" "$WIT_DIR"

# install handwritten packages into the generated project
mkdir -p "$GEN/pgcore" "$GEN/pgpool" "$GEN/platform" "$GEN/httpfacade"
cp "$SRC/pgcore/client.mbt" "$GEN/pgcore/client.mbt"; cp "$SRC/pgcore/protocol.mbt" "$GEN/pgcore/protocol.mbt"; cp "$SRC/pgcore/moon.pkg" "$GEN/pgcore/moon.pkg"
cp "$SRC/pgcore/client_wbtest.mbt" "$GEN/pgcore/client_wbtest.mbt"
cp pgpool.mbt "$GEN/pgpool/pgpool.mbt"; cp pgpool.moon.pkg "$GEN/pgpool/moon.pkg"
cp platform.mbt "$GEN/platform/platform.mbt"; cp platform.moon.pkg "$GEN/platform/moon.pkg"
cp "$SRC/httpfacade/httpfacade.mbt" "$GEN/httpfacade/httpfacade.mbt"; cp httpfacade.moon.pkg "$GEN/httpfacade/moon.pkg"
HPKG="$GEN/gen/interface/wasi/http/handler"
if [ "$MODE" = "dbprobe" ]; then
  cp dbprobe.mbt "$HPKG/handler.mbt"; cp dbprobe.moon.pkg "$HPKG/moon.pkg"
else
  python3 extract.py "$SRC" "$HPKG"
  cp entry.mbt "$HPKG/handler.mbt"; cp server.moon.pkg "$HPKG/moon.pkg"
fi

# pin postgres dep into generated moon.mod
grep -q 'moonbit-community/postgres' "$GEN/moon.mod" || cat >> "$GEN/moon.mod" <<'MOD'
import {
  "moonbit-community/postgres@0.1.3",
  "moonbitlang/x@0.5.6",
  "moonbit-community/unicode-normalization@0.6.0",
  "moonbitstack/mooncred@0.6.1",
  "moonbitstack/mooncrypt@0.3.1",
  "hackwaly/bcrypt@0.1.0",
}
MOD

. "$ROOT/moon-update.sh"
cd "$GEN"
moon_update "$SDK/bin/moon"
"$SDK/bin/moon" fmt
"$SDK/bin/moon" info
"$SDK/bin/moon" build --target wasm --release

CORE="$GEN/_build/wasm/release/build/gen/gen.wasm"
[ -f "$CORE" ] || { echo "expected core missing: $CORE" >&2; exit 1; }
"$SDK/bin/moon-wasm-opt" -O3 --all-features "$CORE" -o "$STAGE/core-opt-$MODE.wasm"
"$TOOLS/bin/wasm-tools" component embed --world server --encoding utf16 "$WIT_DIR" "$STAGE/core-opt-$MODE.wasm" -o "$STAGE/embedded-$MODE.wasm"
"$TOOLS/bin/wasm-tools" component new "$STAGE/embedded-$MODE.wasm" -o "$OUT"
"$TOOLS/bin/wasm-tools" validate "$OUT"
if [ "$MODE" = server ]; then
  mkdir -p "$ROOT/bin"
  cp "$OUT" "$ROOT/bin/conduit.component.wasm"
fi
echo "== imports:" >&2
"$TOOLS/bin/wasm-tools" print "$OUT" | grep -o 'import "[^"]*"' | sort -u >&2 || true
echo "built $OUT"

# publish validated server artifact to ROOT/bin (root start.sh reads it)
ROOT_BIN="$SRC/../bin"
if [ "$MODE" = "server" ]; then
  mkdir -p "$ROOT_BIN"
  cp "$OUT" "$ROOT_BIN/conduit.component.wasm"
  echo "published $ROOT_BIN/conduit.component.wasm"
fi
