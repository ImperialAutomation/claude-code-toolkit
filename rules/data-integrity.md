---
description: Data integrity rules for database operations and migrations
---

# Data Integrity

- Wrap multi-step mutations in a transaction — if any step fails, all changes roll back. No partial state.
- Database constraints are the last line of defense — if a constraint matters, it must exist in the database, not only in application code:
  - `NOT NULL` for required fields
  - `UNIQUE` for no-duplicates
  - `FOREIGN KEY` for referential integrity
  - `CHECK` for value ranges/formats
- Design for idempotency — networks are unreliable, clients retry, webhooks fire twice:
  - Prefer `SET status = 'active'` over `INCREMENT counter`
  - Use idempotency keys for non-naturally-idempotent operations
  - Use `INSERT ... ON CONFLICT DO UPDATE` (upsert) where applicable
- Prevent race conditions — any read-decide-write without protection will eventually produce wrong results:
  - Optimistic locking: `version` column + `WHERE version = ?`
  - Pessimistic locking: `SELECT ... FOR UPDATE`
  - Atomic operations: `UPDATE accounts SET balance = balance - 10 WHERE balance >= 10`
  - Unique constraints over check-then-insert
- Expand-contract migrations — never make breaking schema changes in one step:
  1. Expand: add new column/table with defaults
  2. Backfill data
  3. Deploy new code that uses new structure
  4. Contract: drop old column in a separate migration, after all instances run new code
  - Never add `NOT NULL` without a default
  - Never drop + add replacement in the same migration
- Closed value sets live in one source — if a fixed set of values already
  exists as an enum/constant in code, that is the single source of truth.
  Resolve options/validation live from it; never copy the values into a second
  store (DB column, config row, seeded migration) where they silently drift
  when the enum gains a member. A stored column for the value set is correct
  only when there is NO backing enum (e.g. choices defined at runtime by an
  admin). Enforce with a hook the second time this is violated (see
  code-review rule) — a check that fails any migration seeding the duplicate.
