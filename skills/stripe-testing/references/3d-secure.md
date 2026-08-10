# Stripe test values — 3D Secure / SCA

Captured from [docs.stripe.com/testing](https://docs.stripe.com/testing) on 2026-08-07.
All references are to 3D Secure 2.

**Only the cards on this page meaningfully test a 3DS integration.** Other test
cards may still trigger 3DS, but Stripe returns `attempt_acknowledged` and
bypasses the challenge — a 3DS test built on `pm_card_visa` silently proves
nothing.

**3DS redirects do not occur for payments created in the Stripe Dashboard.**
Drive these tests from your own frontend or an API call.

## Authentication and setup behavior

How the card behaves depends on whether it has been [set up](https://docs.stripe.com/payments/save-and-reuse)
for future off-session payments.

| Description | Number | PaymentMethod |
|---|---|---|
| Authenticate unless set up | 4000002500003155 | `pm_card_authenticationRequiredOnSetup` |
| Always authenticate | 4000002760003184 | `pm_card_authenticationRequired` |
| Already set up for off-session | 4000003800000446 | `pm_card_authenticationRequiredSetupForOffSession` |
| Authenticates, then declines (insufficient funds) | 4000008260003178 | `pm_card_authenticationRequiredChargeDeclinedInsufficientFunds` |

- **Authenticate unless set up** — off-session payments need authentication
  until you set the card up; after setup they don't. On-session payments always
  do.
- **Always authenticate** — every transaction, regardless of setup state.
- **Already set up** — one-time and on-session payments require authentication;
  all off-session payments succeed as if previously set up.
- **Insufficient funds** — authenticates successfully, then declines with
  `insufficient_funds`. Use this to prove your code handles a decline *after* a
  successful 3DS challenge.

## Support and availability

Authentication is requested when regulation, your Radar rules, or your own code
demand it — but it can't always be performed. These cards simulate the
combinations.

| 3DS usage | Outcome | Number | PaymentMethod |
|---|---|---|---|
| Required | OK | 4000000000003220 (IE-issued) | `pm_card_threeDSecure2Required` |
| Required | OK | 4000008400000027 (US-issued) | — |
| Required | Declined after auth | 4000008400001629 | `pm_card_threeDSecureRequiredChargeDeclined` |
| Required | Lookup processing error | 4000008400001280 | `pm_card_threeDSecureRequiredProcessingError` |
| Supported (not required) | OK | 4000000000003055 | `pm_card_threeDSecureOptional` |
| Supported (not required) | Processing error | 4000000000003097 | `pm_card_threeDSecureOptionalProcessingError` |
| Supported | Unenrolled — no challenge | 4242424242424242 | `pm_card_visa` |
| Not supported | Cannot be invoked | 378282246310005 | `pm_card_amex_threeDSecureNotSupported` |
| Frictionless flow | OK | 4000000032200000 | — |

"By default, your Radar rules request 3DS" applies to the *Required* rows; the
*Supported* rows are not requested by default.

Token equivalents: `tok_threeDSecure2Required`,
`tok_threeDSecureRequiredChargeDeclined`, `tok_threeDSecureOptional`,
`tok_amex_threeDSecureNotSupported`, etc.

## Mobile challenge flows

These trigger a specific challenge UI in a **mobile** payment. In browser-based
forms or API calls they work but trigger no special behavior — so Stripe
publishes no `pm_*` or `tok_*` equivalents.

| Challenge flow | Number |
|---|---|
| Out of band | 4000582600000094 |
| One time passcode | 4000582600000045 |
| Single select | 4000582600000102 |
| Multi select | 4000582600000110 |

## SCA context

Strong Customer Authentication has been in force since 14 September 2019 and
requires two-factor authentication for many online payments in the European
Economic Area. The per-country success cards in `cards-success.md` deliberately
succeed *without* authentication — they do not exercise the SCA path. Test both.

A dispute raised as **fraudulent** is protected after 3DS authentication; a
**product not received** dispute is not. See `disputes-refunds.md`.
