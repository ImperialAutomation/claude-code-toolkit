---
name: stripe-testing
description: "Stripe test values and testing procedures — test card numbers, PaymentMethod/token IDs, declines and decline codes, 3D Secure/SCA authentication cards, disputes and evidence values, async refunds, Radar/fraud simulation, SEPA Direct Debit and ACH test accounts, webhook triggering, and test-mode rate limits. TRIGGER — read before writing the code, not after: writing or debugging any test that touches Stripe; needing a specific test card number, pm_* or tok_* value; simulating a decline, dispute, refund, 3DS challenge, or fraud block; testing webhooks or subscription billing; a Stripe test behaving unexpectedly (payment succeeds when it should decline, 3DS not triggering, refund status not transitioning, 429s in test mode). SKIP when the work is a different PSP (Mollie, Adyen, PayPal, Braintree) or is Stripe production/onboarding work with no testing element — for PSP onboarding and integration architecture see the payments rule instead."
user-invocable: true
---

# Stripe Testing

Authoritative test values for simulating Stripe payments without moving funds.
The hard rules (no real cards, no raw PANs in code, no load testing in a
sandbox) are in the `stripe-testing` rule and load automatically — this skill
carries the lookup tables.

## How to use this skill

1. **Identify the scenario** you need to simulate from the table below.
2. **Read only the reference file that covers it** — they are large; don't load
   all of them.
3. **Prefer a `pm_*` PaymentMethod over a raw card number** in any API call or
   server-side test. Raw numbers are for interactive payment-form entry only.

| Scenario | Reference |
|---|---|
| Successful payment, by brand or by country | `references/cards-success.md` |
| Decline, error code, fraud/Radar block, invalid data | `references/cards-decline.md` |
| 3D Secure / SCA authentication, mobile challenge flows | `references/3d-secure.md` |
| Dispute, chargeback, evidence, async refund, payout timing | `references/disputes-refunds.md` |
| SEPA Direct Debit, ACH Direct Debit, microdeposits | `references/non-card.md` |
| Webhooks, Stripe CLI, test clocks, rate limits, sandboxes | `references/workflow.md` |

## The five values worth memorising

Most testing needs only these; look up the rest.

| Purpose | Value |
|---|---|
| Payment succeeds | `pm_card_visa` (number `4242424242424242`) |
| Generic decline | `pm_card_visa_chargeDeclined` (number `4000000000000002`) |
| Insufficient funds | `pm_card_visa_chargeDeclinedInsufficientFunds` (`4000000000009995`) |
| 3DS authentication required | `pm_card_threeDSecure2Required` (`4000000000003220`) |
| Dispute (fraudulent) | `pm_card_createDispute` (`4000000000000259`) |

For interactive entry: any future expiry (e.g. **12/34**), any 3-digit CVC
(4 for Amex), any value for the remaining fields.

## Traps that cost debugging time

- **A skipped check can't fail.** Omit the CVC and Stripe skips CVC
  verification entirely — your "CVC check fails" test then passes for the wrong
  reason. Send a CVC (any 3 digits), a postal code, or a line1 whenever you are
  testing that specific check.
- **Decline cards can't be attached to a Customer.** Attaching fails outright.
  To test a customer whose charge later fails, use `pm_card_chargeCustomerFail`
  (`4000000000000341`) — attaching succeeds, charging fails.
- **3DS redirects don't happen for payments created in the Dashboard.** Drive
  3DS tests from your own frontend or an API call, never from the Dashboard.
- **`4242424242424242` is not a 3DS test card.** It's *unenrolled* — Stripe
  returns `attempt_acknowledged` and skips the challenge, so a 3DS test built on
  it silently proves nothing. Use a card from `references/3d-secure.md`.
- **Async refunds don't fail immediately.** `pm_card_refundFail` starts as
  `succeeded` and transitions to `failed` later via a `refund.failed` event —
  asserting right after the refund call tests the wrong state.
- **429s in test mode aren't a bug in your code.** Test-mode rate limits are
  stricter than live. Slow the requests down; don't load-test a sandbox.
- **Cross-border fees appear in test mode too**, based on the issuer country of
  the test card (JCB, UnionPay, non-US cards). Unexpected fee amounts in a test
  assertion often trace to the card's country, not to your fee logic.

## Keeping this current

These tables were captured from
[docs.stripe.com/testing](https://docs.stripe.com/testing) on **2026-08-07**.
Stripe adds test values over time and occasionally changes behavior. When a
documented value doesn't behave as described, fetch the live page before
concluding the integration is broken — the page is the source of truth, this is
a cache.

Coverage is deliberately partial in two places, both noted in the reference
files: SEPA Direct Debit lists a representative subset of countries rather than
all of them, and Terminal/in-person testing points at Stripe's dedicated
Terminal testing page instead of duplicating it.
