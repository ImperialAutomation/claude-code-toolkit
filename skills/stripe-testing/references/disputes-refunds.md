# Stripe test values — disputes, evidence and refunds

Captured from [docs.stripe.com/testing](https://docs.stripe.com/testing) on 2026-08-07.

## Disputes

With default account settings the charge succeeds, then is disputed.

| Description | Number | PaymentMethod |
|---|---|---|
| Fraudulent | 4000000000000259 | `pm_card_createDispute` |
| Product not received | 4000000000002685 | `pm_card_createDisputeProductNotReceived` |
| Inquiry | 4000000000001976 | `pm_card_createDisputeInquiry` |
| Early fraud warning | 4000000000005423 | `pm_card_createIssuerFraudRecord` |
| Multiple disputes | 4000000404000079 | `pm_card_createMultipleDisputes` |
| Visa Compelling Evidence 3.0 | 4000000404000038 | `pm_card_createCe3EligibleDispute` |
| Visa compliance | 4000008400000779 | `pm_card_createComplianceDispute` |
| Mastercard compliance | 5105008400000002 | `pm_card_createMastercardComplianceDispute` |
| Smart Disputes eligible | 4000000001000043 | `pm_card_createAutoRepresentmentEligibleDispute` |

**3DS protection differs by category:** a *fraudulent* dispute is protected
after 3D Secure authentication; a *product not received* dispute is not. If you
are testing whether 3DS shifts liability, these two cards give opposite — and
both correct — outcomes.

Token equivalents: `tok_createDispute`, `tok_createDisputeInquiry`, etc.

## Evidence — forcing a win or a loss

To close a test dispute with a specific outcome, submit one of these literal
strings as the evidence text:

- via the API: pass it as `evidence[uncategorized_text]` on [dispute update](https://docs.stripe.com/api/disputes/update)
- via the Dashboard or Connect embedded components: enter it in **Additional
  information**, then **Submit evidence**

| Evidence value | Effect |
|---|---|
| `winning_evidence` | Dispute closes as won; your account is credited the charge amount and related fees |
| `losing_evidence` | Dispute closes as lost, no credit. For an inquiry, closes it without escalation |
| `escalate_inquiry_evidence` | Escalates an inquiry to a full chargeback |

## Asynchronous refunds

In live mode refunds are asynchronous: one can look successful and later fail,
or start `pending` and later succeed. With every *other* test card, refunds
succeed immediately and never change status afterwards — which is exactly why a
refund-failure path goes untested unless you use these.

| Description | Number | PaymentMethod | Behavior |
|---|---|---|---|
| Async success | 4000000000007726 | `pm_card_pendingRefund` | Refund starts `pending`, later becomes `succeeded` → `refund.updated` event |
| Async failure | 4000000000005126 | `pm_card_refundFail` | Refund starts `succeeded`, later becomes `failed` → `refund.failed` event |

**Trap:** asserting immediately after calling refund tests the *initial* state,
not the outcome. Wait for the webhook event (`refund.updated` / `refund.failed`)
or poll the refund status.

Token equivalents: `tok_pendingRefund`, `tok_refundFail`.

**Cancelling a card refund** is Dashboard-only. Live mode allows it for a short,
unspecified window; test mode simulates that window as 30 minutes.

## Payout / balance timing

By default a successful test payment lands in the *pending* balance. To get
funds into the available balance immediately, use the bypass-pending cards in
`cards-success.md` (`pm_card_bypassPending`,
`pm_card_bypassPendingInternational`).
