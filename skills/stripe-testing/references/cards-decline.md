# Stripe test values — declines, errors and fraud

Captured from [docs.stripe.com/testing](https://docs.stripe.com/testing) on 2026-08-07.

Assert on the `code` / `decline_code` pair, never on the human-readable
message — the message is not a contract.

## Issuer declines

These return a card error with the listed error code and decline code.

| Description | Number | PaymentMethod | Error code | Decline code |
|---|---|---|---|---|
| Generic decline | 4000000000000002 | `pm_card_visa_chargeDeclined` | `card_declined` | `generic_decline` |
| Insufficient funds | 4000000000009995 | `pm_card_visa_chargeDeclinedInsufficientFunds` | `card_declined` | `insufficient_funds` |
| Lost card | 4000000000009987 | `pm_card_visa_chargeDeclinedLostCard` | `card_declined` | `lost_card` |
| Stolen card | 4000000000009979 | `pm_card_visa_chargeDeclinedStolenCard` | `card_declined` | `stolen_card` |
| Expired card | 4000000000000069 | `pm_card_chargeDeclinedExpiredCard` | `expired_card` | n/a |
| Incorrect CVC | 4000000000000127 | `pm_card_chargeDeclinedIncorrectCvc` | `incorrect_cvc` | n/a |
| Processing error | 4000000000000119 | `pm_card_chargeDeclinedProcessingError` | `processing_error` | n/a |
| Incorrect number | 4242424242424241 | — | `incorrect_number` | n/a |
| Velocity limit exceeded | 4000000000006975 | `pm_card_visa_chargeDeclinedVelocityLimitExceeded` | `card_declined` | `card_velocity_exceeded` |

**Trap:** these cards cannot be attached to a `Customer` — attaching fails
outright. To test a stored customer whose charge later fails, use:

| Description | Number | PaymentMethod |
|---|---|---|
| Decline after attaching | 4000000000000341 | `pm_card_chargeCustomerFail` |

Attaching succeeds; every charge attempt then fails. Token variants add
`tok_visa_chargeCustomerFailLostCard` and `tok_visa_chargeCustomerFailStolenCard`
for lost/stolen-specific failure after attaching.

Token equivalents follow the pattern `tok_visa_chargeDeclined*` /
`tok_chargeDeclined*`.

## Invalid data — no special card needed

Any invalid value triggers these; you don't need a dedicated test card.

| Error code | How to trigger |
|---|---|
| `invalid_expiry_month` | An invalid month, e.g. **13** |
| `invalid_expiry_year` | A year up to 50 years in the past, e.g. **95** |
| `invalid_cvc` | A two-digit number, e.g. **99** |
| `incorrect_number` | A number failing the Luhn check, e.g. `4242424242424241` |

## Radar / fraud simulation

Blocked payments produce a card error with error code `fraud`. Whether a card is
actually blocked depends on **your Radar settings** — only "Always blocked" is
unconditional. A test asserting a block will therefore fail if the account's
Radar rules differ; pin the expectation to the account config or use the
always-blocked card.

**Trap:** to test a *failing* CVC / postal-code / line1 check you must actually
send that field. Stripe skips the check when the field is absent, so the check
cannot fail and your test passes for the wrong reason.

| Description | Number | PaymentMethod | Behavior |
|---|---|---|---|
| Always blocked | 4100000000000019 | `pm_card_radarBlock` | Risk level "highest"; Radar always blocks |
| Highest risk | 4000000000004954 | `pm_card_riskLevelHighest` | Risk "highest"; blocked depending on settings |
| Elevated risk | 4000000000009235 | `pm_card_riskLevelElevated` | Risk "elevated"; may be queued for review |
| High fraud dispute score | 4000008400000407 | `pm_card_highFraudDisputeScore` | May be blocked per settings |
| High early-fraud-warning score | 4000008400000159 | `pm_card_highEfwScore` | May be blocked per settings |
| Dynamic risk thresholds | 4000008400001017 | `pm_card_radarDynamicRiskThreshold` | Blocked if Dynamic risk thresholds enabled |
| Free trial abuse | 4001858821843804 | `pm_card_freeTrialAbuseBlock` | Blocked if free-trial-abuse control enabled |
| Adaptive 3DS | 4000008405600003 | `pm_card_adaptive3dsChallenge` | Requests 3DS if Adaptive 3DS enabled |
| CVC check fails | 4000000000000101 | `pm_card_cvcCheckFail` | Requires a CVC in the request |
| Postal code check fails | 4000000000000036 | `pm_card_avsZipFail` | Requires a postal code in the request |
| CVC fails + elevated risk | 4000058400307872 | `pm_card_cvcCheckFailElevatedRisk` | Requires a CVC |
| Postal code fails + elevated risk | 4000058400306072 | `pm_card_avsZipFailElevatedRisk` | Requires a postal code |
| Line1 check fails | 4000000000000028 | `pm_card_avsLine1Fail` | Succeeds unless a custom Radar rule blocks it |
| Address checks fail (zip + line1) | 4000000000000010 | `pm_card_avsFail` | May be blocked per settings |
| Address checks unavailable | 4000000000000044 | `pm_card_avsUnchecked` | Succeeds unless a custom Radar rule blocks it |

Token equivalents drop the `pm_card_` prefix: `tok_radarBlock`,
`tok_riskLevelHighest`, `tok_cvcCheckFail`, etc.

## Captcha challenge

Stripe may show a captcha on the payment page as a fraud control.

| Description | Number |
|---|---|
| Captcha challenge | 4000000000001208 |
| Captcha challenge | 4000000000003725 |

The charge succeeds if the user answers the captcha correctly.
