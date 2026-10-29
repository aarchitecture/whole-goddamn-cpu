# MoonBit: moonbitlang/async, native, multiprocess

**Front: direct**

RealWorld "Conduit" backend (all 19 endpoints from SPEC.md) in MoonBit.
`start.sh` runs `WORKERS` copies of one native binary on the same
`HOST:PORT` (`SO_REUSEPORT`) plus one bcrypt helper process. Each worker has
one async event loop and its own small PostgreSQL pool; nothing is shared
between processes except the helper.

| Piece | Version |
|---|---|
| MoonBit SDK | moon 0.1.20261023 / moonc v0.10.17+d971670cd (exact pin, sha256-checked in `install.sh`) |
| Async runtime | `moonbitlang/async` 0.22.5 (sockets, tasks, timers) |
| HTTP | own HTTP/1.1 request reader (`src/http_reader.mbt`), one write per response |
| PostgreSQL | own client (`src/pgcore`, wire protocol v3, SCRAM-SHA-256, prepared statements) on `moonbit-community/postgres` 0.1.3 message codecs; own pool (`src/nativepool`) |
| JWT / HMAC | `moonbitstack/mooncred` 0.6.1 (HS256), `moonbitstack/mooncrypt` 0.3.1 |
| bcrypt | vendored from `hackwaly/bcrypt` 0.1.0 (Apache-2.0, `src/pwhash_*.mbt`), cost 10 |
| OS | Ubuntu 24.04, x86_64 |

Dependencies are pinned in `moon.mod`; nothing prebuilt is shipped.

## How it works

- **Session settings** (StartupMessage parameters, no extra round trip):
  `plan_cache_mode=force_generic_plan`, `enable_memoize=off`, `jit=off`,
  `max_parallel_workers_per_gather=0`. Nothing server-wide is changed.
- **Batched reads.** Article by slug, comments, tags, profile, the
  global/tag/author/favorited lists and the feed go through
  `Pool::batched_query`. Requests of one kind that wait while the worker's
  batch connection is busy (or arrive within `DB_BATCH_WAIT_MS`, default 4)
  are sent as one statement: the per-request query is the inner side of a
  `LATERAL` join over `unnest()` of the waiting requests' parameters, and
  every row carries its request's ordinal. Each request gets its own
  execution of its own query while it is being served; subqueries without a
  request parameter (the tag list, the global count) are tied to the request
  row, so nothing is shared between requests and nothing is kept afterwards.
  A failed batch retries each member once on its own. Writes, login,
  `GET /api/user` and ownership checks use a separate small pool.
- **SQL** (`sql.mbt`) returns the same results as SPEC.md's statements:
  pages are cut by ids before the per-article work, tag names are read by
  primary key, the global and tag counts test for a 1000th row
  (`OFFSET 999`) before counting, comments read the viewer's followees once,
  and in the feed `following` is constant `true` (every feed author is
  followed by the viewer in the same snapshot). Article create + tags run in
  one transaction; every write commits before its response. No caches, no
  schema changes.
- **HTTP** (`http.mbt`, `http_reader.mbt`): sequential HTTP/1.1 keep-alive
  per connection, pipelining and split reads handled, `Content-Length`
  bodies up to 1 MiB (413 above, 411 for chunked bodies), `Connection: close`
  honored, connections idle for 75 s closed by one watchdog per connection.
  Handlers see requests through `src/httpfacade`, shared with the WASI
  build. Responses are written straight to UTF-8 from the PostgreSQL cells
  (`jsonw.mbt`) and sent with a single write.
- **Auth** (`auth.mbt`): HS256 JWTs (`sub` = user id, `exp` = +30 days);
  signature, algorithm and `exp` are verified on every request. Passwords
  are bcrypt cost 10 with a 16-byte OS-CSPRNG salt; every login verifies
  against the stored hash. Hashing runs in the bcrypt helper
  (`bcryptd.mbt`, loopback TCP), so a login never blocks a worker's event
  loop. The helper collects jobs for up to `BCRYPT_WAIT_MS` (default 200)
  and runs two to four of them in lockstep (`pwhash_blowfish4.mbt`): each
  still runs the full cost-10 key schedule, the lanes only overlap their
  memory loads (42 ms of CPU per hash instead of ~77 ms when four run
  together). Tests check the lockstep code against the single-lane code.
- **Validation** (`util.mbt`) follows the Go reference: strict `limit`
  (1..100) / `offset` (>= 0), wrapper/field checks, null vs absent fields,
  percent-decoded path segments, 72-byte password limit.

## Processes and configuration

`start.sh` is a foreground supervisor. It starts `BCRYPT_HELPERS` helpers
(default 1; 0 hashes inside the workers), then `WORKERS` workers (default
`min(nproc, 8)`, at most 47). Each worker opens `DB_POOL_SIZE` connections
for single statements and transactions (default 2) and `DB_BATCH_CONNS`
for batched reads (default 1): 24 connections with 8 workers.
`WORKERS * (DB_POOL_SIZE + DB_BATCH_CONNS)` must stay <= 95; invalid values
are rejected before anything starts. The first child to exit stops all the
others and the supervisor exits nonzero; nothing is restarted. SIGTERM
stops everything and exits 0, SIGINT exits 130.

The generated C is compiled with `-O3` (`src/moon.pkg`) instead of moon's
default `-O2`, keeping moon's `-fwrapv -fno-strict-aliasing
-ffp-contract=off`.

## Build and run

```bash
sudo bash install.sh            # root: build-essential + pinned MoonBit SDK
bash build.sh                   # normal user -> bin/conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 \
bash start.sh                   # foreground; answers GET /api/tags within seconds
```

`install.sh` puts the SDK in `/opt/moonbit-challenge/toolchains/moon-0.1.20261023`
(`MOON_TOOLCHAIN_ROOT`); `build.sh` writes only inside this directory
(`MOON_HOME=./.moon-home`).

Conformance: `bash test/run.sh submissions/moonbit-async-a1x-an` (197/197).
Unit tests: `moon test --target native` with the pinned SDK.

## WASI 0.3 backend (experimental)

The same handlers and SQL also build as a WASI 0.3 component (WIT
interfaces pinned to WASI v0.3.2) served by Wasmtime 50.0.0; see
[wasip3/README.md](wasip3/README.md).

```bash
sudo env BACKEND=wasip3 bash install.sh
BACKEND=wasip3 bash build.sh
BACKEND=wasip3 DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

The core module is run through the SDK's `moon-wasm-opt -O3` before it is
wrapped as a component (about 8% less CPU at the same load). It passes the
conformance suite (197/197). Each component instance has one
PostgreSQL connection and one active request; bcrypt runs inline. It is much
slower than the native build and is not the submitted configuration.

## Own measurements (not the official score)

Challenge-style search on an 8-vCPU Ice Lake / 16 GB stand with the same PostgreSQL
config, load generated from a separate machine: fresh database, 3-minute
warm-up, 2-minute probes, then a 5-minute hold.

| Build | Highest passing hold | req/s | p95 / p99 | Errors |
|---|---:|---:|---:|---:|
| native | 90000 users | 23337 | 294 / 743 ms | 0 |
| WASI 0.3 | 20000 users | 4996 | 443 / 608 ms | 0 |

Native probes failed at 92000 (p95 574 ms); WASI probes failed at 21000
(p95 522 ms).

## Rules checklist

- PostgreSQL only, session-level settings only, schema untouched.
- No caching across requests: only connections and prepared statements are
  reused; batching shares statements, never results.
- Writes commit before the response; bcrypt cost 10 for every hash and every
  login; JWT signature and `exp` checked on every request.
- No hard-coded responses, no load-test detection, no host tuning, no
  restarts of crashed processes; built from source with pinned versions.
