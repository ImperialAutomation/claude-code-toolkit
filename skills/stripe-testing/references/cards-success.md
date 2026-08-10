# Stripe test values — successful payments

Captured from [docs.stripe.com/testing](https://docs.stripe.com/testing) on 2026-08-07.

Prefer the `pm_*` PaymentMethod in API calls and server-side tests. Raw card
numbers are for interactive entry in a payment form only. For interactive
entry: any future expiry (**12/34**), any 3-digit CVC (4 digits for Amex).

Cross-border fees are assessed on the *issuer* country, in test mode too — JCB,
UnionPay and other non-US cards can carry a cross-border fee in your test
assertions.

## By card brand

| Brand | Number | PaymentMethod | Token | CVC |
|---|---|---|---|---|
| Visa | 4242424242424242 | `pm_card_visa` | `tok_visa` | 3 digits |
| Visa (debit) | 4000056655665556 | `pm_card_visa_debit` | `tok_visa_debit` | 3 digits |
| Mastercard | 5555555555554444 | `pm_card_mastercard` | `tok_mastercard` | 3 digits |
| Mastercard (2-series) | 2223003122003222 | — | — | 3 digits |
| Mastercard (debit) | 5200828282828210 | `pm_card_mastercard_debit` | `tok_mastercard_debit` | 3 digits |
| Mastercard (prepaid) | 5105105105105100 | `pm_card_mastercard_prepaid` | `tok_mastercard_prepaid` | 3 digits |
| American Express | 378282246310005 | `pm_card_amex` | `tok_amex` | 4 digits |
| American Express | 371449635398431 | — | — | 4 digits |
| Discover | 6011111111111117 | `pm_card_discover` | `tok_discover` | 3 digits |
| Discover | 6011000990139424 | — | — | 3 digits |
| Discover (debit) | 6011981111111113 | — | — | 3 digits |
| Diners Club | 3056930009020004 | `pm_card_diners` | `tok_diners` | 3 digits |
| Diners Club (14-digit) | 36227206271667 | — | — | 3 digits |
| BCcard / DinaCard | 6555900000604105 | — | — | 3 digits |
| JCB | 3566002020360505 | `pm_card_jcb` | `tok_jcb` | 3 digits |
| UnionPay | 6200000000000005 | `pm_card_unionpay` | `tok_unionpay` | 3 digits |
| UnionPay (debit) | 6200000000000047 | — | — | 3 digits |
| UnionPay (19-digit) | 6205500000000000004 | — | — | 3 digits |

### Co-branded cards

Most Cartes Bancaires and eftpos cards are co-branded with Visa or Mastercard.

| Brand / co-brand | Number | PaymentMethod |
|---|---|---|
| Cartes Bancaires / Visa | 4000002500001001 | `pm_card_visa_cartesBancaires` |
| Cartes Bancaires / Mastercard | 5555552500001001 | `pm_card_mastercard_cartesBancaires` |
| eftpos Australia / Visa | 4000050360000001 | `pm_card_visa_debit_eftposAuCoBranded` |
| eftpos Australia / Mastercard | 5555050360000080 | `pm_card_mastercard_debit_eftposAuCoBranded` |

Tokens follow the same naming: `tok_visa_cartesBancaires`, etc.

## By country

Success without authentication. **SCA note:** cards in the Europe/Middle East
block simulate a payment that succeeds *without* 3DS — they do not exercise
your SCA path. Test authentication separately with `references/3d-secure.md`.

The `pm_*` and `tok_*` values follow a consistent pattern: `pm_card_<cc>` and
`tok_<cc>` using the lowercase ISO country code (e.g. `pm_card_hu`, `tok_hu`).

### Americas

| Country | Number | PaymentMethod | Brand |
|---|---|---|---|
| United States (US) | 4242424242424242 | `pm_card_us` | Visa |
| Argentina (AR) | 4000000320000021 | `pm_card_ar` | Visa |
| Brazil (BR) | 4000000760000002 | `pm_card_br` | Visa |
| Canada (CA) | 4000001240000000 | `pm_card_ca` | Visa |
| Chile (CL) | 4000001520000001 | `pm_card_cl` | Visa |
| Colombia (CO) | 4000001700000003 | `pm_card_co` | Visa |
| Costa Rica (CR) | 4000001880000005 | `pm_card_cr` | Visa |
| Ecuador (EC) | 4000002180000000 | `pm_card_ec` | Visa |
| Mexico (MX) | 4000004840008001 | `pm_card_mx` | Visa |
| Mexico (MX) | 5062210000000009 | — | Carnet |
| Panama (PA) | 4000005910000000 | `pm_card_pa` | Visa |
| Paraguay (PY) | 4000006000000066 | `pm_card_py` | Visa |
| Peru (PE) | 4000006040000068 | `pm_card_pe` | Visa |
| Uruguay (UY) | 4000008580000003 | `pm_card_uy` | Visa |

### Europe and Middle East

| Country | Number | PaymentMethod | Brand |
|---|---|---|---|
| United Arab Emirates (AE) | 4000007840000001 | `pm_card_ae` | Visa |
| United Arab Emirates (AE) | 5200007840000022 | `pm_card_ae_mastercard` | Mastercard |
| Austria (AT) | 4000000400000008 | `pm_card_at` | Visa |
| Belgium (BE) | 4000000560000004 | `pm_card_be` | Visa |
| Bulgaria (BG) | 4000001000000000 | `pm_card_bg` | Visa |
| Belarus (BY) | 4000001120000005 | `pm_card_by` | Visa |
| Croatia (HR) | 4000001910000009 | `pm_card_hr` | Visa |
| Cyprus (CY) | 4000001960000008 | `pm_card_cy` | Visa |
| Czech Republic (CZ) | 4000002030000002 | `pm_card_cz` | Visa |
| Denmark (DK) | 4000002080000001 | `pm_card_dk` | Visa |
| Estonia (EE) | 4000002330000009 | `pm_card_ee` | Visa |
| Finland (FI) | 4000002460000001 | `pm_card_fi` | Visa |
| France (FR) | 4000002500000003 | `pm_card_fr` | Visa |
| Germany (DE) | 4000002760000016 | `pm_card_de` | Visa |
| Gibraltar (GI) | 4000002920000005 | `pm_card_gi` | Visa |
| Greece (GR) | 4000003000000030 | `pm_card_gr` | Visa |
| **Hungary (HU)** | **4000003480000005** | **`pm_card_hu`** | Visa |
| Ireland (IE) | 4000003720000005 | `pm_card_ie` | Visa |
| Italy (IT) | 4000003800000008 | `pm_card_it` | Visa |
| Latvia (LV) | 4000004280000005 | `pm_card_lv` | Visa |
| Liechtenstein (LI) | 4000004380000004 | `pm_card_li` | Visa |
| Lithuania (LT) | 4000004400000000 | `pm_card_lt` | Visa |
| Luxembourg (LU) | 4000004420000006 | `pm_card_lu` | Visa |
| Malta (MT) | 4000004700000007 | `pm_card_mt` | Visa |
| Netherlands (NL) | 4000005280000002 | `pm_card_nl` | Visa |
| Norway (NO) | 4000005780000007 | `pm_card_no` | Visa |
| Poland (PL) | 4000006160000005 | `pm_card_pl` | Visa |
| Portugal (PT) | 4000006200000007 | `pm_card_pt` | Visa |
| Romania (RO) | 4000006420000001 | `pm_card_ro` | Visa |
| Saudi Arabia (SA) | 4000006820000007 | — | Visa |
| Slovenia (SI) | 4000007050000006 | `pm_card_si` | Visa |
| Slovakia (SK) | 4000007030000001 | `pm_card_sk` | Visa |
| Spain (ES) | 4000007240000007 | `pm_card_es` | Visa |
| Sweden (SE) | 4000007520000008 | `pm_card_se` | Visa |
| Switzerland (CH) | 4000007560000009 | `pm_card_ch` | Visa |
| United Kingdom (GB) | 4000008260000000 | `pm_card_gb` | Visa |
| United Kingdom (GB) | 4000058260000005 | `pm_card_gb_debit` | Visa (debit) |
| United Kingdom (GB) | 5555558265554449 | `pm_card_gb_mastercard` | Mastercard |

### Asia Pacific

| Country | Number | PaymentMethod | Brand |
|---|---|---|---|
| Australia (AU) | 4000000360000006 | `pm_card_au` | Visa |
| China (CN) | 4000001560000002 | `pm_card_cn` | Visa |
| Hong Kong (HK) | 4000003440000004 | `pm_card_hk` | Visa |
| India (IN) | 4000003560000008 | `pm_card_in` | Visa |
| Japan (JP) | 4000003920000003 | `pm_card_jp` | Visa |
| Japan (JP) | 3530111333300000 | `pm_card_jcb` | JCB |
| Malaysia (MY) | 4000004580000002 | `pm_card_my` | Visa |
| New Zealand (NZ) | 4000005540000008 | `pm_card_nz` | Visa |
| Singapore (SG) | 4000007020000003 | `pm_card_sg` | Visa |
| Taiwan (TW) | 4000001580000008 | `pm_card_tw` | Visa |
| Thailand (TH) | 4000007640000003 | `pm_card_th_credit` | Visa (credit) |
| Thailand (TH) | 4000057640000008 | `pm_card_th_debit` | Visa (debit) |

India subscriptions requiring mandates and pre-debit notifications have their
own procedure — see Stripe's India recurring payments testing docs.

## Simulate a customer's location by email

For Checkout Sessions, Payment Links and pricing tables, add a `+location_XX`
suffix (ISO 3166-1 alpha-2) to the local part of an email to simulate a
customer's country — you then see the currency and payment methods that
customer would see.

```
test+location_US@example.com    → simulates a US customer
test+location_HU@example.com    → simulates a Hungarian customer
```

Pass it as `customer_email` when creating a Checkout Session, or as the
`prefilled_email` URL parameter for a Payment Link.

## HSA / FSA cards

| Type | Number | PaymentMethod |
|---|---|---|
| Visa FSA | 4000051230000072 | `pm_card_debit_visaFsaProductCode` |
| Visa HSA | 4000051230000072 | `pm_card_debit_visaHsaProductCode` |
| Mastercard FSA | 5200828282828897 | `pm_card_mastercard_debit_mastercardFsaProductCode` |

## Send funds straight to the available balance

Normally a successful test payment lands in the *pending* balance. These cards
bypass it — useful when a test needs a withdrawable balance immediately.

| Description | Number | PaymentMethod |
|---|---|---|
| Bypass pending (US charge) | 4000000000000077 | `pm_card_bypassPending` |
| Bypass pending (international) | 4000003720000278 | `pm_card_bypassPendingInternational` |
