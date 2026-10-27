# C: miserable submission

Front: direct

god fucking damn it i paid for the whole CPU and i'm gonna USE the whole CPU

anyways long story short i went insane making this :) when i started i only had scooter1337 as my competition, but eventually others started showing up and i had to keep on frying the same fuckass codebase.

moving on, here are the very cool tricks i've used:

- two workers! each worker gets its own `SO_REUSEPORT` listener, so the kernel load-balances the accepts and there is zero shared state between workers. no locks, no shared pools, no work stealing, no mutex-shaped regrets. two is the default because a worker batches concurrent reads of the same kind, and two bigger batches cost less Postgres work than eight small ones.
- everything lives in one epoll set. client sockets, listening sockets and every libpq connection of a worker sit in the same epoll. there is no "database thread" and no thread pool, so nobody is ever waiting on a queue while another thread is idle. the event loop is the whole architecture.
- handlers are state machines over libpq's async API. a bcrypt login is ~60–100 ms of pure CPU; a slow client write can take forever, a big scan can take even longer and none of it blocks anybody else, because nothing ever blocks. it just suspends and gets resumed by the next epoll event. this is the structurally impossible version of the worker-starvation bug that determines the usual C submission score.
- read batching. quite annoying to implement without abstractions, actually. reads of one kind get queued per worker and go out as ONE prepared statement with `unnest` arrays. a batch leaves at `READ_BATCH` (64) requests or when the oldest one has waited `READ_WINDOW_MS` (20 ms), whichever comes first. `LIST_QUERY` / `LIST_ALL` then compute pages, capped counts, tags and author rows once per distinct article/key inside that one statement, the rows come back with the request ordinal, and i demultiplex them. the batch is thrown away right after the callbacks run. this is within-statement work, i don't think this was against the rules.
- write group commit, also quite cancer to implement without abstractions. all writes of a worker go onto one write lane. a lone write waits up to `WRITE_WINDOW_MS` (5 ms) for friends; a queue of `WRITE_IMMEDIATE` (4) or more leaves immediately. the lane pipelines up to `WRITE_GROUP` (32) prepared writes and closes with a single `PQpipelineSync`, so one durable commit serves the whole group. every response still waits for that commit, obviously.


honorable mention to bullshit that didn't meet the list: 'TCP_NODELAY` on client sockets (coalescing hurts interactive p99 and the responses are single writes anyway), idle keep-alive at 70 s so it outlives Nginx's 60 s upstream idle (and, in direct mode, bounds the memory of idle browser connections), two-buffer request arenas, and one allocation per response write.

## stuff you can change

- `WORKERS` (default 2), `READ_BATCH` (64), `READ_WINDOW_MS` (20), `WRITE_GROUP` (32), `WRITE_WINDOW_MS` (5), `CRYPTO_THREADS` (one per core).
- do please tune this, as these are the numbers i actually used for testing 50k locally and are DEFINITELY fucked on a real server.
