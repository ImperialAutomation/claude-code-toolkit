---
description: Error handling standards for all application code
---

# Error Handling

- Never swallow errors — every error must be either handled (corrective action) or propagated (caller deals with it). Logging and continuing is not handling.
- Add context when propagating — each layer adds what it was doing. Final message reads as a chain: `"create order: charge payment: POST /payments: connection refused"`
- Translate errors at boundaries:
  - Repository → Service: `sql.ErrNoRows` → `ErrUserNotFound`
  - Service → Handler: `ErrUserNotFound` → HTTP 404
  - Unexpected errors → HTTP 500 with generic message
- Never expose internals in error responses — no stack traces, SQL errors, file paths, or dependency names
- API error responses must use RFC 9457 Problem Details format (`application/problem+json`):
  - `type` — stable URI identifier (clients match on this)
  - `title` — short human-readable summary
  - `status` — HTTP status code
  - `detail` — specific occurrence explanation
  - `errors` — field-level validation errors (extension field)
- Log errors with full context at the boundary where they're translated: operation name, user_id, request_id, error chain/stack trace, relevant resource IDs
- Distinguish error categories: retriable (5xx, timeout) vs terminal (4xx, business rule) vs corruption (data integrity)
