---
description: API design standards for HTTP APIs
---

# API Design

- Use standard HTTP status codes — don't invent custom ones:

  | Code | When |
  |------|------|
  | 200 | Successful GET, PUT, PATCH |
  | 201 | Successful POST that creates a resource |
  | 204 | Successful DELETE or action with no response body |
  | 400 | Malformed request (unparseable JSON, wrong content type) |
  | 401 | Missing or invalid authentication |
  | 403 | Authenticated but not authorized |
  | 404 | Resource not found (prefer 404 over 403 to avoid leaking existence) |
  | 409 | Conflict (duplicate, version mismatch) |
  | 422 | Valid request but business rule violation |
  | 429 | Rate limit exceeded (include `Retry-After` header) |
  | 500 | Unexpected server error |

- 400 vs 422: 400 = syntactically broken (can't parse). 422 = valid structure but semantically invalid (business rule).
- All error responses follow RFC 9457 Problem Details (see error-handling rule)
- Validate request body, query params, and path params at the handler layer — reject invalid input immediately with 400/422 and field-level error details
- Collections use cursor-based pagination: `items`, `hasMore`, `nextCursor`
- Never expose internals: no stack traces, SQL errors, file paths, or internal identifiers in responses
- Rate limiting headers on all responses: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`
