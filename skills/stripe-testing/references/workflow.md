# Stripe testing — sandboxes, webhooks and limits

Captured from [docs.stripe.com/testing](https://docs.stripe.com/testing) on 2026-08-07.

## Sandboxes

A sandbox is an isolated test environment inside your account: test transactions
that don't move funds and don't touch the live integration. Reach them through
the account picker in the [Dashboard](https://dashboard.stripe.com/sandboxes).

## Test API keys

Use test keys for every call in a test, whether serving a payment form
interactively or running automated tests. Test keys cannot process live
payments; live keys must never appear in source or config committed to version
control — environment variables or a secrets vault only. See Stripe's
[key best practices](https://docs.stripe.com/keys-best-practices).

## Interactive vs. code

| Context | Use |
|---|---|
| Payment form, Dashboard, manual click-through | Raw card number, e.g. `4242 4242 4242 4242`, expiry **12/34**, any CVC |
| API calls, server-side code, automated tests | A PaymentMethod, e.g. `pm_card_visa` |

Raw card numbers in server-side code risk putting that code path outside PCI
compliance once it goes live, even if it started as "just a test". A test
PaymentMethod is not attached to a Customer by default.

## Testing webhooks / event destinations

Two approaches:

1. **Drive real events** — perform actions in the sandbox that legitimately
   produce the event (e.g. charge a success card to get `charge.succeeded`).
   Slower, but exercises the real payload.
2. **Trigger events directly** with the [Stripe CLI](https://docs.stripe.com/webhooks#test-webhook)
   (`stripe trigger <event>`) or the Stripe VS Code extension. Fast and precise,
   but the payload is synthetic.

Use approach 1 for the integration test that must be right, approach 2 for
breadth across event types.

**Always test double delivery.** Stripe delivers the same event more than once
in production; a test firing each event exactly once cannot catch a
double-charge. Deliver the same event ID twice and assert a single effect. See
the data-integrity rule for the idempotency patterns (upsert over increment, key
on the event ID).

## Rate limits

Test-mode rate limits are **stricter than live mode**. If you start seeing `429`
responses, slow the requests down.

Do not load-test through the Stripe API in a sandbox: the stricter limiter
produces failures you'd never see in production, so the results are misleading.
Stripe documents a separate approach under
[load testing](https://docs.stripe.com/rate-limits#load-testing).

## Related rules in this toolkit

- `rules/stripe-testing.md` — the non-negotiables (loads automatically on
  payment-related files)
- `rules/payments.md` — PSP onboarding, provider abstraction, SDK pinning,
  currency decimals
- `rules/data-integrity.md` — idempotency and race-condition patterns that
  webhook handling depends on
- `rules/testing.md` — general test-quality policy
