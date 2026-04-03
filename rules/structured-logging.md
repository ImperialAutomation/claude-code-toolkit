---
description: Structured logging standards for application code
---

# Structured Logging

- Use structured key-value pairs, not string interpolation:
  - Good: `logger.info("order_created", user_id=user.id, order_id=order.id, total=order.total)`
  - Bad: `logger.info(f"User {user.id} created order {order.id}")`
- Use consistent field names across the codebase:

  | Field | Type | Description |
  |-------|------|-------------|
  | `user_id` | string | User identifier |
  | `request_id` | string | Request correlation ID |
  | `session_id` | string | Session identifier |
  | `error_type` | string | Error class/type name |
  | `duration_ms` | number | Operation duration |
  | `operation` | string | What was being attempted |

- Choose the right severity level:

  | Level | When |
  |-------|------|
  | DEBUG | Diagnostic detail — disabled in production |
  | INFO | Normal operations worth recording (server started, request completed) |
  | WARN | Unexpected but handled (retry succeeded, deprecated API called, client 4xx) |
  | ERROR | Operation failed, requires attention (DB query failed, external API unreachable, 5xx) |
  | FATAL | System cannot continue (OOM, config missing, port in use) |

- Never log secrets (passwords, API keys, tokens, PII) — log presence instead: `api_key_present=true`
- Always include stack trace / error chain when logging errors
- Use module-scoped loggers named after their module (enables per-module level configuration)
- Log at system boundaries, not inside tight loops
