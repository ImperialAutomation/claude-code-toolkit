# Stripe test values — non-card payment methods

Captured from [docs.stripe.com/testing](https://docs.stripe.com/testing) on 2026-08-07.

**Coverage is deliberately partial.** SEPA Direct Debit publishes a full set per
country; this file carries a representative subset (AT, BE, DE, FR, IE, plus the
naming pattern) covering the scenarios you actually test. For a country not
listed, fetch the live page — the *scenarios* are identical everywhere, only the
IBANs differ.

Use test API keys for all of these, same as for cards.

## SEPA Direct Debit

Procedure: create a test PaymentMethod with a test IBAN, then use it in a
`confirmSepaDebitPayment` request.

Every country exposes the same scenario set, with tokens named
`pm_sepaDebit_<scenario>_<cc>`:

| Scenario | Token suffix | Behavior |
|---|---|---|
| Success | `success` | `processing` → `succeeded` |
| Delayed success | `successDelayed` | `processing` → `succeeded` after ≥3 minutes |
| Failure | `failed` | `processing` → `requires_payment_method` |
| Delayed failure | `failedDelayed` | `processing` → `requires_payment_method` after ≥3 min |
| Disputed | `disputed` | `processing` → `succeeded`, dispute created immediately |
| Weekly volume limit | `exceedsWeeklyVolumeLimit` | Fails with `charge_exceeds_source_limit` |
| Weekly transaction limit | `exceedsWeeklyTransactionLimit` | Fails with `charge_exceeds_weekly_limit` |
| Insufficient funds | `insufficientFunds` | Fails with `insufficient_funds` |
| Bank doesn't support SEPA DD | (no token) | PaymentMethod creation fails, `sepa_debit_bank_not_supported` |
| Account can't be debited | (no token) | PaymentMethod creation fails, `sepa_debit_debits_not_supported` |

The last two apply to SetupIntents and PaymentIntents that include inline IBAN
data, and fail at *creation* time rather than at charge time.

**The delayed variants are the ones worth wiring into a test.** A SEPA
integration that only tests the instant path never exercises the `processing`
state your UI has to render.

### Austria (AT)

| IBAN | Token |
|---|---|
| AT611904300234573201 | `pm_sepaDebit_success_at` |
| AT321904300235473204 | `pm_sepaDebit_successDelayed_at` |
| AT861904300235473202 | `pm_sepaDebit_failed_at` |
| AT051904300235473205 | `pm_sepaDebit_failedDelayed_at` |
| AT591904300235473203 | `pm_sepaDebit_disputed_at` |
| AT981904300000343434 | `pm_sepaDebit_exceedsWeeklyVolumeLimit_at` |
| AT601904300000121212 | `pm_sepaDebit_exceedsWeeklyTransactionLimit_at` |
| AT981904300002222227 | `pm_sepaDebit_insufficientFunds_at` |
| AT271904300000055555 | (bank not supported) |
| AT511904300000066666 | (debits not supported) |

### Belgium (BE)

| IBAN | Token |
|---|---|
| BE62510007547061 | `pm_sepaDebit_success_be` |
| BE78510007547064 | `pm_sepaDebit_successDelayed_be` |
| BE68539007547034 | `pm_sepaDebit_failed_be` |
| BE51510007547065 | `pm_sepaDebit_failedDelayed_be` |
| BE08510007547063 | `pm_sepaDebit_disputed_be` |
| BE90510000343434 | `pm_sepaDebit_exceedsWeeklyVolumeLimit_be` |
| BE52510000121212 | `pm_sepaDebit_exceedsWeeklyTransactionLimit_be` |
| BE90510002222227 | `pm_sepaDebit_insufficientFunds_be` |
| BE19510000055555 | (bank not supported) |
| BE43510000066666 | (debits not supported) |

### Germany (DE)

| IBAN | Token |
|---|---|
| DE89370400440532013000 | `pm_sepaDebit_success_de` |
| DE08370400440532013003 | `pm_sepaDebit_successDelayed_de` |
| DE62370400440532013001 | `pm_sepaDebit_failed_de` |
| DE78370400440532013004 | `pm_sepaDebit_failedDelayed_de` |
| DE35370400440532013002 | `pm_sepaDebit_disputed_de` |
| DE65370400440000343434 | `pm_sepaDebit_exceedsWeeklyVolumeLimit_de` |
| DE27370400440000121212 | `pm_sepaDebit_exceedsWeeklyTransactionLimit_de` |
| DE65370400440002222227 | `pm_sepaDebit_insufficientFunds_de` |
| DE91370400440000055555 | (bank not supported) |
| DE18370400440000066666 | (debits not supported) |

### France (FR)

| IBAN | Token |
|---|---|
| FR1420041010050500013M02606 | `pm_sepaDebit_success_fr` |
| FR3020041010050500013M02609 | `pm_sepaDebit_successDelayed_fr` |
| FR8420041010050500013M02607 | `pm_sepaDebit_failed_fr` |
| FR7920041010050500013M02600 | `pm_sepaDebit_failedDelayed_fr` |
| FR5720041010050500013M02608 | `pm_sepaDebit_disputed_fr` |
| FR9720041010050000000343434 | `pm_sepaDebit_exceedsWeeklyVolumeLimit_fr` |
| FR5920041010050000000121212 | `pm_sepaDebit_exceedsWeeklyTransactionLimit_fr` |
| FR9720041010050000002222227 | `pm_sepaDebit_insufficientFunds_fr` |
| FR2620041010050000000055555 | (bank not supported) |
| FR5020041010050000000066666 | (debits not supported) |

### Ireland (IE)

| IBAN | Token |
|---|---|
| IE29AIBK93115212345678 | `pm_sepaDebit_success_ie` |
| IE24AIBK93115212345671 | `pm_sepaDebit_successDelayed_ie` |
| IE02AIBK93115212345679 | `pm_sepaDebit_failed_ie` |
| IE94AIBK93115212345672 | `pm_sepaDebit_failedDelayed_ie` |
| IE51AIBK93115212345670 | `pm_sepaDebit_disputed_ie` |
| IE10AIBK93115200343434 | `pm_sepaDebit_exceedsWeeklyVolumeLimit_ie` |
| IE69AIBK93115200121212 | `pm_sepaDebit_exceedsWeeklyTransactionLimit_ie` |
| IE10AIBK93115202222227 | `pm_sepaDebit_insufficientFunds_ie` |
| IE36AIBK93115200055555 | (bank not supported) |
| IE60AIBK93115200066666 | (debits not supported) |

### Other countries

Stripe also publishes SEPA test IBANs for HR, EE, FI, GI, LI, LT, LU, MT, NL,
NO, PL, PT, RO, SI, SK, ES, SE, CH and GB, following the identical scenario and
token-naming pattern. Fetch [docs.stripe.com/testing](https://docs.stripe.com/testing)
when you need one.

## ACH Direct Debit (US)

### Test account numbers

All use routing number `110000000`.

| Account number | Token | Behavior |
|---|---|---|
| `000123456789` | `pm_usBankAccount_success` | Payment succeeds |
| `000111111113` | `pm_usBankAccount_accountClosed` | Fails — account closed |
| `000000004954` | `pm_usBankAccount_riskLevelHighest` | Blocked by Radar (high fraud risk) |
| `000111111116` | `pm_usBankAccount_noAccount` | Fails — no account found |
| `000222222227` | `pm_usBankAccount_insufficientFunds` | Fails — insufficient funds |
| `000333333335` | `pm_usBankAccount_debitNotAuthorized` | Fails — debits not authorized |
| `000444444440` | `pm_usBankAccount_invalidCurrency` | Fails — invalid currency |
| `000666666661` | `pm_usBankAccount_failMicrodeposits` | Fails to send microdeposits |
| `000555555559` | `pm_usBankAccount_dispute` | Triggers a dispute |
| `000000000009` | `pm_usBankAccount_processing` | Stays in `processing` indefinitely — use to test PaymentIntent cancellation |
| `000777777771` | `pm_usBankAccount_weeklyLimitExceeded` | Fails — weekly volume limit |
| `000888888885` | — | Fails — deactivated tokenized account number |

Accounts that auto-succeed or auto-fail must be **verified first** using the
microdeposit values below.

### Microdeposit amounts and descriptor codes

Use either the two amounts *or* the 0.01 descriptor code.

| Microdeposit values | Descriptor code | Scenario |
|---|---|---|
| `32` and `45` | SM11AA | Verifies the account |
| `10` and `11` | SM33CC | Exceeds allowed verification attempts |
| `40` and `41` | SM44DD | Microdeposit timeout |

### Transaction emails in a sandbox

Mandate-confirmation and microdeposit-verification emails only send when the
address carries a `+test_email` suffix: `{username}+test_email@{domain}` — e.g.
`info+test_email@example.com`. Without the suffix, no email is sent. The Stripe
account must be set up before these emails trigger.

### Settlement timing

Test ACH transactions settle **instantly** into the available balance. Live mode
takes multiple days — so any test asserting on settlement timing is testing
sandbox behavior, not production behavior.

Instant verification via Financial Connections has its own test accounts — see
Stripe's Financial Connections testing docs.

## Terminal / in-person payments

For a payment involving a PIN:

| Description | Number | PaymentMethod |
|---|---|---|
| Offline PIN | 4001007020000002 | `offline_pin_cvm` |
| Offline PIN retry (SCA) | 4000008260000075 | `offline_pin_sca_retry` |
| Online PIN | 4001000360000005 | `online_pin_cvm` |
| Online PIN retry (SCA) | 4000002760000008 | `online_pin_sca_retry` |

The resulting charge carries
`payment_method_details.card_present.receipt.cardholder_verification_method` set
to `offline_pin` / `online_pin`. The retry cards simulate a contactless charge
failing and the reader then prompting for card insertion and a PIN.

Terminal has a much broader testing surface (simulated readers, physical test
cards) documented separately at
[docs.stripe.com/terminal/references/testing](https://docs.stripe.com/terminal/references/testing) —
not duplicated here.
