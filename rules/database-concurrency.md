---
description: Sync vs async DB-access lanes and connection-pool hardening
paths: "**/database/**, **/db/**, **/models/**, **/repositories/**, **/*session*, **/*engine*, **/api/**, **/routes/**, **/endpoints/**, **/worker*/**, **/tasks/**"
---

# Database Concurrency

Pick one DB-access lane and stay in it. Mixing sync and async is the trap, not
either one on its own. (Lesson A8 — PAM.)

## Sync vs async: choose deliberately, never by cargo-cult

- **Sync engine → `def` route handlers, never `async def`** for DB-touching routes.
  FastAPI runs `def` handlers in a threadpool (no event-loop blocking). A **sync**
  `Session` inside an `async def` route blocks the event loop on *every query* — the
  most common FastAPI footgun. PAM shipped 87 `async def` routes holding a sync
  `Session`, doing synchronous DB work with no `await` in the body: pure overhead and
  a latent outage, chosen by copying FastAPI examples, never decided.
- **`async def` only when there is real async I/O** — an actual `await` on an async
  client/SDK. Don't propagate `async` through services/helpers that do no real I/O;
  async that awaits nothing is cost without benefit.
- **Web tier and Celery/worker tier share one session/repository style.** Celery
  workers are sync processes; a sync web lane gives you a single tenant-context /
  repository layer for both. If a framework you build on is fully sync (e.g. GenAI
  Launchpad: sync engine + sync `Session`, web and workers on the same `db_session`),
  an async web lane beside it means two incompatible DB worlds on one database —
  including duplicating any tenant-context / `SET LOCAL` machinery.
- This is an enforced rule, not advice: a `def`-only-for-DB-routes check belongs in
  lint/review the second it's violated (see code-review rule, A1).

## Pool hardening is foundation work, not incident response

Bake these into the engine setup from day one — don't wait for the outage that
teaches them (PAM learned via a 40-minute stuck-pool outage):

- `pool_pre_ping=True` — replace dead connections before handing them out; log the
  replacement so degrading pool health is visible early, not discovered mid-outage.
- Explicit `pool_size` / `max_overflow`, sized under PostgreSQL's `max_connections`
  (Postgres default 100; e.g. 20 + 30 = 50 leaves headroom).
- Server-side timeouts via `connect_args` so the database self-heals even if the app
  fails to clean up:
  - `idle_in_transaction_session_timeout` (~60s) — PG kills sessions sitting idle
    inside a transaction (the classic stuck-pool cause).
  - `statement_timeout` (~30s) — PG kills runaway queries. Override per-transaction
    for known-long operations with `SET LOCAL statement_timeout = '...'` (scoped to
    the current transaction; reverts on return to the pool).

## Triggers to re-evaluate the sync default

- A genuinely I/O-bound, high-concurrency web tier emerges (many concurrent external
  calls in the request path) — then a *fully* async lane (async engine **and**
  `async def` **and** async I/O) may be worth it. Switch the whole lane, never mix.
- Threadpool saturation becomes the measured bottleneck under load.
