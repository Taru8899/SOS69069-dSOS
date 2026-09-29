## SOS69069 dSOS

An ownerless ETH contract with three parallel offer instruments (B / T / P) and a credit-based common pool, both gated by real signed records on the external **SOS69069** reputation ledger.

dSOS does not issue a transferable ERC-20/721 token — `name()`/`symbol()` exist purely for wallet display.

**Compiler:** Solidity `0.8.36` (pinned, no floating pragma).

## Core constants

| Constant | Value | Purpose |
|---|---|---|
| `SOS69069_LEDGER` | `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` | External ledger this deployment reads/writes |
| `UNIT` | `0.006 ether` | Base amount used by the credit redemption rate formula |
| `MIN_RESERVE` | `0.000999 ether` | Floor the common pool must stay above after any credit payout |
| `DEAD_ZONE_PAYOUT` | `0.0000033 ether` (≈ $0.01) | Flat payout at the dead-zone position, instead of 0 |
| `RATE_STEP` | `1001` | Points of `\|effective\|` per 1% step in the credit rate |
| `BASE_RATE_PCT` | `30` | Starting rate of each cycle |
| `CYCLE_STEPS` | `71` | 70 climbing steps (30%→99%) + 1 dead-zone step |
| `DEAD_ZONE_POS` | `70` | Position that pays `DEAD_ZONE_PAYOUT` instead of a percentage of `UNIT` |

SOS69069 itself has no transferable asset and rejects ETH outright — it only records signed messages and exposes live `Push`, `Trust`, and `effectiveOf() = Trust − Push` counters.

## Offer types (B / T / P)

All three share the same technical skeleton: creation writes one SOS record with a typed marker → claim is transferable → redemption writes one SOS record and pays the locked ETH in full → `totalEarmarked` accounting is identical → atomicity with the ledger is identical.

**None of the three types can ever be cancelled.** Once created, an offer can only be transferred (`transferOffer`) or redeemed (`redeemOffer`) by its current holder — the original donor has no way to reclaim the locked ETH under any circumstance, at any time.

**B-type — Exact Seller Offer**
- Poster locks a specific ETH amount for a designated address.
- Only the designated address (or a later holder it's transferred to) can redeem.
- On redeem, the holder writes 1 SOS record targeting the original poster and receives the full principal.
- Economic meaning: *"I lock ETH to buy 1 SOS record from this exact person."*

**T-type — Public Trust Buy Offer**
- Poster locks ETH and publicly offers to buy 1 Trust record.
- Anyone who ends up holding the claim can redeem.
- On redeem, the holder writes a record targeting the original poster and receives the ETH.
- Economic meaning: *"I lock ETH to buy 1 Trust from anyone."*

**P-type — Push Service Offer**
- Poster publicly advertises: *"I will accept ETH locked for me and in return I will Push the original locker."*
- Anyone can lock ETH (or transfer an existing claim) toward the P-poster.
- The P-poster redeems by writing a Push record targeting the original locker and receives the ETH.
- Economic meaning: *"I will Push you if you lock ETH for me."*

`OfferType` (`B`/`T`/`P`) is stored on-chain per offer purely as a label distinguishing the intended economic meaning above — the contract enforces the same mechanics (transfer, redeem, no cancel) identically across all three; the distinction is informational, carried in the type field and in off-chain metadata conventions, not in different contract logic.

## Common pool — donation only, no individual claims

- `donateCommon(payloadHash, signature, metadata)`: donor sends any ETH amount, writes a record `donor → SOS69069_LEDGER`, and the ETH joins the shared pool. **No offer is minted** — this is a non-redeemable donation.
- Plain ETH sent via `receive()` also joins the pool, with no record and no offer.
- `commonPool()` = contract balance minus `totalEarmarked` — the pool never includes ETH backing an active offer.
- **The common pool can only grow** (via `receive()`/`donateCommon`) **and can only shrink via `redeemCredit` payouts.** No function reimburses gas from the pool.

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
- A credit redemption's own ledger record targets `SOS69069_LEDGER`, raising the caller's Push, not their Trust — so it cannot mint a replacement credit for itself.
- No weighting, no conversion ratio, no remainder — every new trust record earns exactly 1 credit.
- Callable by anyone, on any address, at any time via `syncCredits(user)`. `pendingCredits(user)` previews the result without writing state.

## Redeeming a credit — `redeemCredit(payloadHash, signature, metadata)`

- Burns 1 credit.
- Pays according to the sawtooth rate cycle:
  - `step = |effectiveOf(caller)| / RATE_STEP`
  - `cyclePos = step % CYCLE_STEPS`
  - if `cyclePos == DEAD_ZONE_POS (70)`: pays a flat `DEAD_ZONE_PAYOUT` (≈$0.01)
  - otherwise: pays `UNIT × (BASE_RATE_PCT + cyclePos) / 100` — i.e. 30% through 99% of `UNIT`
  - the cycle then repeats every `71 × 1001 = 71,071` points of `|effective|`, symmetric for positive and negative values.
- Must leave `commonPool()` at or above `MIN_RESERVE` after paying out, or the call reverts.
- The credit is always spent on a successful call, even in the dead zone.
- No activity floor, no reputation-band gate — any `effectiveOf()` value is redeemable, just at a different rate.

## Atomicity — the core guarantee

Every state-changing function follows the same pattern: **local state is fully updated first, then the external ledger call happens, then (for redemptions) ETH is sent.** If `SOS.recordSignature(...)` reverts for any reason — invalid signature, duplicate record, wrong signer — the entire transaction reverts, undoing every state change made earlier in that same call. There is no path where an offer is marked redeemed, a credit is spent, or ETH leaves the contract without a corresponding successful signed record landing on the SOS69069 ledger in that same transaction.

## Safety

- `nonReentrant` guard on every state-changing function (`donateCommon`, `createOffer`, `transferOffer`, `redeemOffer`, `redeemCredit`).
- All local state finalized before the external `recordSignature` call in every function.
- `totalEarmarked` is only ever incremented in `createOffer` and decremented in `redeemOffer` — `transferOffer` never touches it.
- `commonPool()` always excludes `totalEarmarked`, so offer principal can never be reached through `redeemCredit`.
- **No cancellation of any kind, for any offer type.** Once created, an offer's principal belongs to whoever ends up holding it — the original donor can never reclaim it.
- **No gas reimbursement of any kind.** Every function's caller pays their own transaction gas; nothing is refunded from the common pool.
- Principal stored as `uint96` (creation reverts above the cap), counters as `uint128`, for tight storage packing.
- No owner, no admin functions, no upgradeability, no pause switch.

## Views

| Function | Returns |
|---|---|
| `commonPool()` | ETH available for credit redemption (balance minus earmarked) |
| `poolBalance()` | Total contract ETH balance |
| `isEligible(user)` | True iff `user` currently has at least one spendable credit |
| `signerMetrics(user)` | Raw `push`, `trust`, `effective` values from the ledger |
| `pendingCredits(user)` | Live credit balance as of a hypothetical sync now |
| `offerCountOf(holder)` / `offerIdsOf(holder)` | Offers currently held by an address |
| `offers(id)` | Full offer details (donor, holder, principal, active, kind, recordHash) |
| `lastTrust(user)` / `redemptionCredits(user)` | Raw account storage |
| `ratePercentOf(eff)` | The payout rate, in percent, for a given effective score |
| `quoteRedeemCredit(user)` | The current rate and payout `user` would receive right now |

## Summary

Three parallel offer instruments (B / T / P) let anyone lock any amount of ETH against a signed SOS69069 record requirement. B is a non-cancellable exact-seller claim; T is a public "I buy one Trust"; P is a public "I will Push you if you lock ETH for me." All three are transferable, none can ever be cancelled, and redemption always pays the current holder the full locked amount. Separately, the common pool pays out credits earned purely from trust activity, at a rate that cycles with the redeemer's effective score — climbing from 30% to 99% of `UNIT` every 71,071 points of `\|effective\|`, dropping to a flat token payout at the dead zone, then repeating. The pool only grows from donations and only shrinks from these credit payouts — nothing is ever reimbursed for gas, and nothing locked in an offer can ever be reclaimed by its original donor.
```
