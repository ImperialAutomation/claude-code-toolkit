---
description: Payment provider (PSP) onboarding and integration rules
---

# Payments

## Before onboarding to a PSP

- **Check the prohibited/restricted-business list FIRST** — before filling in any business details. PSPs reject or restrict whole categories, and the rejection often comes *after* you submit, mid-onboarding (categories like dating, gambling, crypto, and parts of financial services are commonly restricted — verify yours before investing onboarding effort).
  - Stripe: [stripe.com/legal/restricted-businesses](https://stripe.com/legal/restricted-businesses)
  - Distinguish **prohibited** (never allowed) from **restricted** (allowed only with prior written approval).
- **Positioning matters as much as the business itself.** The same product can land in a clean or a restricted category depending on how you describe it at onboarding. Map your business to the safest accurate category and avoid trigger terms.
  - Example (real estate): a *listing marketplace / classifieds + SaaS subscription* is clean; "real estate **investment** platform" or "property **brokerage**" hits the restricted financial-services rule. The PSP touching the underlying money-flow (escrow, purchase sums) is what triggers it — not advertising/subscription revenue.
  - Pick an MCC consistent with the safe category; a mismatched MCC can re-trigger the restricted rule.
- **Legal pages are an onboarding gate, not a launch task.** PSPs require public Terms, Privacy, and Pricing pages (+ GDPR consent in the EU) before account activation. Build these at project start — scrambling to ship `/terms`, `/privacy`, and `/pricing` at activation time is a common avoidable fire drill.
- **Verify entity eligibility for your jurisdiction** — that the PSP onboards your legal entity type and settles in your currency to a local bank account. Don't assume "region X = standard pricing"; pull the country-specific pricing page.

## Integration

- **Abstract the provider behind your own interface.** No provider-SDK calls scattered through the codebase — one internal `PaymentProvider` contract (create-customer, create-subscription, charge-once, webhook-verify) with the concrete PSP as one implementation behind it. Keeps the provider replaceable without a rewrite.
- **Pin the PSP SDK version with an upper bound** (`pkg>=X,<X+1`) — a major-version bump can break every call in a day. PSP SDKs ship breaking changes on major bumps; an unbounded range will eventually pull one in unannounced.
- **Don't assume the PSP covers tax/invoicing compliance.** Region-specific e-invoicing (e.g. Hungary's NAV Online Számla, Italy's SDI) is a separate component fed by the PSP's invoice API/webhooks — design it standalone.
- **Currency decimal handling differs per currency.** Some currencies are zero-decimal for payouts even if charges allow decimals (e.g. Stripe treats HUF as zero-decimal for payouts — payout amounts must be integers divisible by 100). Verify per settlement currency in your amount logic.
- **Design webhooks for idempotency** — they fire more than once; key on the event/resource ID and use upserts, not increments. (See data-integrity rule.)
