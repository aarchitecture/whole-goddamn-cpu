# wasip3 (experimental WASI 0.3 mode)

Full Conduit server as a pure-MoonBit WASI 0.3 component: the native
business files are byte-copied into the generated wasi:http/handler
package over a pure-MoonBit PostgreSQL facade (own implementation,
not the native driver). Default `build.sh` mode is the full server;
`build.sh dbprobe` produces the older DB-only probe artifact.

## Files

- `world.wit` - conduit:server@0.1.0 world (cli/clocks/random/sockets/
  ip-name-lookup/http 0.3.2, exports wasi:http/handler)
- `client.mbt` / `client.moon.pkg` - platform-independent codec layer:
  ClientError(DatabaseError{code,message}), Row + get[T:FromSql] with
  NULL-aware Option[T], TEXT ToSql params (String/Int/Int64/Bool/
  Option[T]/Array[String] always-quoted), BINARY FromSql decoders
  (int widths w/ Int32 range check, bool, text OIDs 25/1043/1042/19/18,
  binary text[] via pinned PgArray parser rejecting NULL elems/ndim>1)
- `pgpool.mbt` / `pgpool.moon.pkg` - Pool facade: one physical
  connection per Pool serialized by semaphore(1), lazy deadline-bound
  connect (5000ms monotonic watchdog), startup auth trust/cleartext/
  SCRAM-SHA-256 (fresh WASI CSPRNG nonce, MD5 rejected, TLS unsupported),
  per-connection LRU prepared-statement cache (capacity 100; Parse+
  Describe on a miss, Bind+Execute+Sync on a hit) with TEXT binds and
  BINARY results, each request packet emitted as one socket write (WASI
  sockets cannot set TCP_NODELAY; split writes stalled ~40 ms per query on
  Linux via Nagle + delayed ACK), buffered frame reads via
  `client.FrameBuffer` (16MiB guard before allocation), in_flight/txn_status tracking,
  error path reads through ReadyForQuery then discards broken conn,
  with_transaction(Transaction) with BEGIN/COMMIT/ROLLBACK semantics
- `platform.mbt` - env/rand/now shim on generated WASI interfaces
- `dbprobe.mbt` / `dbprobe.moon.pkg` - probe handler (health/db)
- `build.sh` - staged regen + build + componentize + validate

## Full server

From the submission root (parent of this directory):

```bash
sudo env BACKEND=wasip3 bash install.sh
BACKEND=wasip3 bash build.sh
BACKEND=wasip3 DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge WORKERS=4 WASI_INSTANCES=80 \
HOST=127.0.0.1 PORT=3000 bash start.sh
python3 wasip3/tests/http_test.py --base http://127.0.0.1:3000
```

Tools are pinned to `wit-bindgen 0.63.0`, `wasm-tools 1.262.0`, and
`Wasmtime 50.0.0`, with SHA-256 checked release archives. The default
`WASI03_TOOLS` is `/opt/moonbit-challenge/wasi03-tools`.
The normal-user build stages under `$XDG_CACHE_HOME/conduit-wasip3`
(or `$HOME/.cache/conduit-wasip3`); `WASI03_STAGE` overrides it.
The published artifact is `bin/conduit.component.wasm`.

`WORKERS` sets host Tokio threads, default `min(nproc, 8)`.
`WASI_INSTANCES` defaults to 80 and cannot exceed 95. Each component has
one active request, at most one PostgreSQL connection, and a 64 MiB
linear-memory limit (not a limit on total host RSS). `DB_POOL_SIZE`, if
set, must be 1. The launcher stays in the foreground and forwards signals
to its own Wasmtime child. Guest environment contains only `DATABASE_URL`
and `JWT_SECRET`; no filesystem directories are preopened. Network access
is inherited for PostgreSQL, not restricted to a single address by this CLI.

The direct HTTP connection cap is explicitly 100000, independent of the
active-request/component/PG budget. Wasmtime 50 otherwise defaults to only
1000 TCP connections, including idle keep-alives. An idle browser connection
does not need its own component or database connection. The challenge's
200000 open-file limit is required for large direct-connection loads.

SQL, business logic and the HTTP facade (`src/httpfacade`) are shared with
the native build. The alternate PG facade has 5-second operation deadlines and
a 16 MiB frame guard. Request bodies are capped at 1 MiB. SCRAM, cleartext
and trust are supported; TLS and MD5 are not. Bcrypt still runs
synchronously inside each isolated guest. This is experimental, not a
claim of production certification or a performance advantage.

## DB probe

```bash
export WASI03_STAGE="${WASI03_STAGE:-${XDG_CACHE_HOME:-$HOME/.cache}/conduit-wasip3}"
bash build.sh dbprobe
wasmtime serve -Scli -Sp3 -Sinherit-network=y -W component-model-async=y \
  --addr 127.0.0.1:13026 \
  --max-instance-concurrent-reuse-count 1 --max-concurrent-requests 1 \
  --max-instance-reuse-count 9223372036854775807 \
  --idle-instance-timeout 3600s -O pooling-allocator=y \
  -O pooling-total-component-instances=1 -O pooling-max-memory-size=67108864 \
  --env PROBE_PG_HOST=127.0.0.1 --env PROBE_PG_PORT=5432 \
  --env PROBE_PG_USER=postgres --env PROBE_PG_DB=postgres \
  "$WASI03_STAGE/dbprobe.component.wasm"
```

GET /db hard-asserts the fixed read-only SQL set (SELECT 1, typed
$1..$5 params with Unicode/arrays/NULL variants, division 22012 +
reuse, zero-row, transaction rollback + reuse, pg_backend_pid) and
returns 200 {"status":"ok","pid":..} only when every assertion holds.
Functional verification only - no benchmark, no performance claims.

## Full Conduit server mode (default)

`build.sh server` (default) byte-copies the native business files
(auth/users/articles/comments/sql/util) plus named blocks from
http.mbt/main.mbt into the generated handler package - no forked logic.
Produces `conduit.component.wasm`.

Run: `wasip3/start.sh` or `wasmtime serve ... conduit.component.wasm`
with `DATABASE_URL` + `JWT_SECRET` exported (one PG connection per
component instance, WASI_INSTANCES pooled instances, WORKERS tokio
threads). `BACKEND=wasip3` on the root build.sh/start.sh delegates here.

Provenance: verbatim business source reuse; experimental WASI 0.3
transport; verified 197/197 conformance on a clone DB. No performance
claims.

The pgcore Wasm tests run in the generated WASI module with `cd <STAGE>/gen-server && moon test --target wasm -p conduit/wasip3/pgcore`.
