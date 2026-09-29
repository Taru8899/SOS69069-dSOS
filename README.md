###SOS69069 dSOS

An ownerless ETH contract with three parallel offer instruments (B / T / P) and a credit-based common pool, both gated by real signed records on the external **SOS69069** reputation ledger.

dSOS does not issue a transferable ERC-20/721 token — `name()`/`symbol()` exist purely for wallet display.

Compiler: Solidity 0.8.36 (pinned, no floating pragma).

## Core constants

| Constant | Value | Purpose |
|---|---|---|
| `SOS69069_LEDGER` | `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` | External ledger this deployment reads/writes |
| `UNIT` | `0.006 ether` | Base amount used by the credit redemption rate formula |
| `MIN_RESERVE` | `0.000999 ether` | Floor the common pool must stay above after any credit payout or gas refund |
| `RATE_STEP` | `1001` | Points of \|effective\| per 1 % step in the credit rate |
| `BASE_RATE_PCT` | `30` | Starting rate of each cycle |
| `CYCLE_STEPS` | `71` | 70 climbing steps (30 %→99 %) + 1 dead-zone step (0 %) |
| `DEAD_ZONE_POS` | `70` | Position that pays 0 % |
| `CANCEL_BLOCKS` | `50_400` (≈ 7 days) | Block-based timeout for cancellable offer types |
| `GAS_OVERHEAD` | `25_000` | Extra gas added when calculating refunds |

SOS69069 itself has no transferable asset and rejects ETH outright — it only records signed messages and exposes live `Push`, `Trust`, and `effectiveOf() = Trust − Push` counters.

## Offer types (B / T / P)

All three share the same technical skeleton:  
creation writes one SOS record with a typed marker → claim is transferable → redemption writes one SOS record and pays the locked ETH → `totalEarmarked` accounting is identical → atomicity with the ledger is identical.

### B-type – Exact Seller Offer
**Marker format:**  
`B:{id}|{amount}ETH|ends on day MM DD YY on block {createdBlock + CANCEL_BLOCKS}`

- Poster locks a specific amount of ETH for a designated address.
- Only the designated address (or later holders) can redeem.
- On redeem the holder must write 1 SOS record → original poster and receives the full principal.
- **Cannot be cancelled** under any circumstances.
- No effectiveOf check, no activity check.
- Economic meaning: “I lock ETH to buy 1 SOS record from this exact person.”

### T-type – Public Trust Buy Offer
**Marker format:**  
`T:{id}|{amount}ETH|ends on day MM DD YY on block {createdBlock + CANCEL_BLOCKS}`

- Poster locks ETH and publicly offers to buy 1 Trust.
- Anyone who ends up holding the claim can redeem.
- On redeem the holder must write a **Trust** record → original poster and receives the ETH.
- Original poster can cancel after `CANCEL_BLOCKS` and reclaim the ETH (even if transferred).
- Economic meaning: “I lock ETH to buy 1 Trust from anyone.”

### P-type – Push Service Offer
**Marker format:**  
`P:{id}|{amount}ETH|ends on day MM DD YY on block {createdBlock + CANCEL_BLOCKS}`

- Poster publicly advertises: “I will accept ETH locked for me and in return I will Push the original locker.”
- Anyone can lock ETH (or transfer an existing claim) toward the P-poster.
- The P-poster redeems by writing a **Push** record → original locker and receives the ETH.
- Original poster can cancel after `CANCEL_BLOCKS`.
- Economic meaning: “I will Push you if you lock ETH for me.”

## Common pool — donation only, no individual claims

- `donateCommon(payloadHash, signature, metadata)`: donor sends any ETH amount, writes a record `donor → SOS69069_LEDGER`, and the ETH joins the shared pool. No offer is minted — this is a non-redeemable donation.
- Plain ETH sent via `receive()` also joins the pool, with no record and no offer.
- `commonPool()` = contract balance minus `totalEarmarked` — the pool never includes ETH backing an active offer.

## Credits — only trust increases earn credits

```text
_sync(user):
  (push, trust, eff) = SOS.statsOf(user)
  if trust > lastTrust[user]:
    earned = trust - lastTrust[user]
    credits[user] += earned
    lastTrust[user] = trust
    emit CreditsSynced(...)
  return push, trust, eff, credits[user]
```

- Only increases in `trustCountOf()` produce credits. Push records earn nothing.
- A credit redemption’s own ledger record raises the caller’s Push, not their Trust, so it cannot mint a replacement credit.
- No weighting, no conversion ratio, no remainder — every new trust record earns exactly 1 credit.
- Callable by anyone, on any address, at any time via `syncCredits(user)`. `pendingCredits(user)` previews the result without writing state.

## Redeeming a credit — `redeemCredit(payloadHash, signature, metadata)`

- Burns 1 credit.
- Pays `UNIT × ratePercent(effectiveOf(caller)) / 100`.
- Rate follows the sawtooth cycle (30 %→99 %, then 0 % dead zone, then repeats).
- Must leave the common pool above `MIN_RESERVE`.
- Credit is always spent, even when the rate is 0 %.
- No activity or lifetime requirements of any kind.

## Gas reimbursement

Every state-changing function measures its own gas usage and refunds the caller from the common pool.  
The refund is automatically reduced (or set to zero) if paying the full amount would bring the common pool below `MIN_RESERVE`.  
Earmarked funds are never used for refunds.

## Atomicity — the core guarantee

Every state-changing function follows the same pattern: **local state is fully updated first, then the external ledger call happens, then (for redemptions) ETH is sent.** If `SOS.recordSignature(...)` reverts for any reason — invalid signature, duplicate record, wrong signer — the entire transaction reverts, undoing every state change made earlier in that same call. There is no path where an offer is marked redeemed, a credit is spent, or ETH leaves the contract without a corresponding successful signed record landing on the SOS69069 ledger in that same transaction.

## Safety

- `nonReentrant` guard on every state-changing function.
- All local state finalized *before* the external `recordSignature` call in every function.
- `totalEarmarked` is only ever incremented on creation and decremented on redeem/cancel.
- `commonPool()` always excludes `totalEarmarked`, so offer principal can never be reached through `redeemCredit` or gas refunds.
- B offers cannot be cancelled; T and P offers can be cancelled only after the block timeout.
- Principal stored as `uint96`, counters as `uint128`, for tight storage packing.
- No owner, no admin functions, no upgradeability, no pause switch.

## Discoverability

All open offers are visible on the SOS ledger by scanning for metadata that begins with `B:`, `T:` or `P:`.  
The date + block field always states the exact cancel deadline in the form:  
`ends on day MM DD YY on block XXXX`.

## Views

| Function | Returns |
|---|---|
| `commonPool()` | ETH available for credit redemption and gas refunds (balance minus earmarked) |
| `poolBalance()` | Total contract ETH balance |
| `isEligible(user)` | True iff `user` currently has at least one spendable credit |
| `signerMetrics(user)` | Raw `push`, `trust`, `effective` values from the ledger |
| `pendingCredits(user)` | Live credit balance as of a hypothetical sync now |
| `offerCountOf(holder)` / `offerIdsOf(holder)` | Offers currently held by an address |
| `offers(id)` | Full offer details (donor, holder, principal, active, createdBlock, kind, recordHash) |
| `lastTrust(user)` / `redemptionCredits(user)` | Raw account storage |
| `ratePercentOf(eff)` | Current payout rate for a given effective score |
| `quoteRedeemCredit(user)` | Current rate and payout the user would receive |

## Summary

Three parallel offer instruments (B / T / P) let anyone lock ETH against a SOS record requirement.  
B is a non-cancellable exact-seller claim.  
T is a public “I buy one Trust”.  
P is a public “I will Push you if you lock ETH for me”.  

Separately, the common pool pays credits earned from trust activity at a rate that cycles with the caller’s effective score.  
Every action reimburses its own gas from the common pool while protecting the minimum reserve.
```