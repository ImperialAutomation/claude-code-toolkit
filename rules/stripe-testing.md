---
paths: "**/*stripe*, **/*payment*, **/*billing*, **/*checkout*, **/*subscription*"
---

# Stripe Testing

Non-negotiables when testing a Stripe integration. Full test-value tables
(cards, PaymentMethods, SEPA/ACH accounts, 3DS, disputes) live in the
`stripe-testing` skill — invoke it when you need a specific value.

- **Never use real card details in test mode.** The Stripe Services Agreement
  prohibits it. Use test API keys plus the documented test values, always.
- **Never put raw card numbers in API calls or server-side code** — not even in
  tests. Use a test `PaymentMethod` (`pm_card_visa`, `pm_card_visa_chargeDeclined`,
  …). Raw PANs in server code put the integration outside PCI scope compliance
  when the same code path goes live. Raw numbers are for interactive entry in a
  payment form only.
- **Test keys and live keys are separate worlds.** Test keys can't process live
  payments and live keys must never appear in source, config files, or a
  lockfile — environment variables or a secrets vault only.
- **A test sandbox is not a load-test target.** Rate limits are *stricter* in
  test mode than in live mode, so load testing produces `429`s you'd never see
  in production and tells you nothing. See Stripe's load-testing guidance.
- **Assert on the error/decline code, not on the message.** Decline test cards
  return a stable `code` + `decline_code` pair (e.g. `card_declined` +
  `insufficient_funds`); the human-readable message is not a contract.
- **A check that can be skipped can't fail.** Stripe skips CVC, postal-code and
  address verification when you omit those fields — so a test for "CVC check
  fails" must actually send a CVC. Same for postal code and line1.
- **Cover more than the happy path.** A payment integration needs at minimum:
  success, a decline, a 3D Secure authentication flow, an asynchronous
  refund, and a webhook replay. Card-success-only is not a tested integration.
- **Webhook tests must prove idempotency.** Stripe delivers the same event more
  than once; a test that fires each event exactly once will not catch a
  double-charge. Deliver the same event ID twice and assert one effect.
  (See data-integrity rule.)

Source: [docs.stripe.com/testing](https://docs.stripe.com/testing) — verify
against the live page when a value doesn't behave as documented.
