## SOS69069 dSOS

An ownerless ETH contract with three parallel offer instruments (B / T / P), a credit-based common pool, and a minimal embedded GasClaim token. Everything is gated by real signed records on the external **SOS69069** reputation ledger.

```markdown
## How SOS69069 dSOS works (User Guide)

The contract has three main things you can do:

### 1. Create or take an Offer (B / T / P)

You can lock ETH into an **Offer**. There are three types, but they all work the same way on-chain:

- **B-type** → “I lock ETH and want 1 SOS record from a *specific* person.”
- **T-type** → “I lock ETH and want 1 Trust record from *anyone*.”
- **P-type** → “I am willing to Push anyone who locks ETH for me.”

**What happens:**
1. Someone locks ETH and creates an offer (writes a SOS record at the same time).
2. The offer can be freely transferred to other people.
3. Whoever currently holds the offer can redeem it by writing the required SOS record → they receive the full locked ETH.
4. Once created, an offer **can never be cancelled**. The original person who locked the ETH can never get it back.

### 2. Earn and spend Credits

- Every time your **Trust** count increases on the SOS69069 ledger, you earn 1 credit.
- You can check your pending credits at any time.
- You can transfer credits to other people (clean transfer, no history attached).
- You can burn 1 credit to receive ETH from the common pool.

**How much ETH you get for 1 credit** depends on your current `effective` score (Trust − Push). It follows a repeating cycle:

- Starts at 30% of 0.006 ETH
- Climbs up to 99% of 0.006 ETH
- Then hits a “dead zone” that pays only ≈ $0.01
- Then the cycle restarts at 30% again

There is no minimum activity requirement and no reputation band you must be inside or outside of. Any effective score is allowed — you just get paid at a different rate.

### 3. Donate to the Common Pool + GasClaim

- Anyone can send ETH to the contract (plain transfer or `donateCommon`).
- This ETH goes into the shared common pool.
- Every time you donate a non-zero amount, you also receive 1 wei of a tiny token called **GasClaim**.
- You can later burn GasClaim to get the same amount of ETH back from the pool (1:1).
- Because gas fees are much higher than 1 wei, GasClaim has almost no practical value — it is mainly a receipt that you donated.

### Important rules users should know

- Everything important (creating offers, redeeming, transferring credits, etc.) requires a real signed SOS69069 record in the same transaction.
- If the SOS record fails, the whole action is cancelled — no partial state changes.
- The common pool can never go below a small safety reserve.
- There is no owner, no admin, and no way to pause or upgrade the contract.
- Offers are permanent once created. Credits and GasClaim can be moved or spent freely.

### Simple summary

| Action                        | What you do                          | What you get                          |
|-------------------------------|--------------------------------------|---------------------------------------|
| Create Offer                  | Lock ETH + write SOS record          | A transferable claim on that ETH      |
| Redeem Offer                  | Write the required SOS record        | The full locked ETH                   |
| Earn Credits                  | Increase your Trust on SOS69069      | 1 credit per new Trust                |
| Spend Credit                  | Burn 1 credit                        | ETH (amount depends on your score)    |
| Transfer Credits              | Send credits to someone else         | Clean transfer                        |
| Donate                        | Send ETH to the contract             | 1 wei GasClaim + support the pool     |
| Redeem GasClaim               | Burn GasClaim                        | Same amount of ETH back               |
```

dSOS does not issue a transferable ERC-20/721 token for the main contract — `name()`/`symbol()` exist purely for wallet display.  
GasClaim is a separate minimal ERC20 embedded in the same contract.

**Compiler:** Solidity `0.8.36` (pinned, no floating pragma).

## Core constants

| Constant | Value | Purpose |
|---|---|---|
| `SOS69069_LEDGER` | `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` | External ledger this deployment reads/writes |
| `UNIT` | `0.006 ether` | Base amount used by the credit redemption rate formula |
| `MIN_RESERVE` | `0.000999 ether` | Floor the common pool must stay above after any credit or GasClaim payout |
| `DEAD_ZONE_PAYOUT` | `0.0000033 ether` (≈ $0.01) | Flat payout at the dead-zone position, instead of 0 |
| `RATE_STEP` | `1001` | Points of `\|effective\|` per 1% step in the credit rate |
| `BASE_RATE_PCT` | `30` | Starting rate of each cycle |
| `CYCLE_STEPS` | `71` | 70 climbing steps (30%→99%) + 1 dead-zone step |
| `DEAD_ZONE_POS` | `70` | Position that pays `DEAD_ZONE_PAYOUT` instead of a percentage of `UNIT` |
| `GAS_CLAIM_MINT` | `1` wei | Fixed amount of GasClaim minted on every nonzero donation |

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

- `donateCommon(payloadHash, signature, metadata)`: donor sends any ETH amount, writes a record `donor → SOS69069_LEDGER`, and the ETH joins the shared pool. **No offer is minted** — this is a non-redeemable donation. Also mints 1 wei of GasClaim to the donor.
- Plain ETH sent via `receive()` also joins the pool, with no record and no offer. Also mints 1 wei of GasClaim if `msg.value > 0`.
- `commonPool()` = contract balance minus `totalEarmarked` — the pool never includes ETH backing an active offer.
- **The common pool can only grow** (via `receive()`/`donateCommon`) **and can only shrink via `redeemCredit` or `redeemGasClaim` payouts.** No function reimburses gas from the pool.

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
- Credits can be transferred freely via `transferCredits` (clean provenance-free hop). The transfer also writes a SOS record.

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

## GasClaim — minimal embedded ERC20

- Every nonzero ETH donation (`receive()` or `donateCommon`) mints exactly `1 wei` of GasClaim to the donor.
- GasClaim is a minimal ERC20 (`transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, `totalSupply`).
- `redeemGasClaim(amount, ...)` burns `amount` GasClaim and pays the same amount of wei from the common pool (1:1).
- Because a full transaction costs far more than 1 wei, GasClaim is economically irrelevant as a farming vector. It remains in the contract as a lightweight receipt of donation activity.

## Atomicity — the core guarantee

Every state-changing function follows the same pattern: **local state is fully updated first, then the external ledger call happens, then (for redemptions) ETH is sent.** If `SOS.recordSignature(...)` reverts for any reason — invalid signature, duplicate record, wrong signer — the entire transaction reverts, undoing every state change made earlier in that same call. There is no path where an offer is marked redeemed, a credit is spent, GasClaim is burned, or ETH leaves the contract without a corresponding successful signed record landing on the SOS69069 ledger in that same transaction.

## Safety

- `nonReentrant` guard on every state-changing function, including `receive()`.
- All local state finalized before the external `recordSignature` call in every function.
- `totalEarmarked` is only ever incremented in `createOffer` and decremented in `redeemOffer` — `transferOffer` never touches it.
- `commonPool()` always excludes `totalEarmarked`, so offer principal can never be reached through `redeemCredit` or `redeemGasClaim`.
- **No cancellation of any kind, for any offer type.** Once created, an offer's principal belongs to whoever ends up holding it — the original donor can never reclaim it.
- **No gas reimbursement of any kind.** Every function's caller pays their own transaction gas; nothing is refunded from the common pool.
- Principal stored as `uint96` (creation reverts above the cap), counters as full `uint256`.
- No owner, no admin functions, no upgradeability, no pause switch.

## Views

| Function | Returns |
|---|---|
| `commonPool()` | ETH available for credit / GasClaim redemption (balance minus earmarked) |
| `poolBalance()` | Total contract ETH balance |
| `isEligible(user)` | True iff `user` currently has at least one spendable credit |
| `signerMetrics(user)` | Raw `push`, `trust`, `effective` values from the ledger |
| `pendingCredits(user)` | Live credit balance as of a hypothetical sync now |
| `offerCountOf(holder)` / `offerIdsOf(holder)` | Offers currently held by an address |
| `offers(id)` | Full offer details (donor, holder, principal, active, kind, recordHash) |
| `lastTrust(user)` / `redemptionCredits(user)` | Raw account storage |
| `ratePercentOf(eff)` | The payout rate, in percent, for a given effective score |
| `quoteRedeemCredit(user)` | The current rate and payout `user` would receive right now |
| `balanceOf` / `allowance` / `totalSupply` | Standard GasClaim ERC20 views |

## Summary

Three parallel offer instruments (B / T / P) let anyone lock any amount of ETH against a signed SOS69069 record requirement. B is a non-cancellable exact-seller claim; T is a public "I buy one Trust"; P is a public "I will Push you if you lock ETH for me." All three are transferable, none can ever be cancelled, and redemption always pays the current holder the full locked amount.

Separately, the common pool pays out credits earned purely from trust activity, at a rate that cycles with the redeemer's effective score — climbing from 30% to 99% of `UNIT` every 71,071 points of `|effective|`, dropping to a flat ≈$0.01 payout at the dead zone, then repeating. Credits themselves can be transferred freely.

A minimal GasClaim token is minted (1 wei) on every nonzero donation and can be redeemed 1:1 for ETH from the pool. Because gas costs dominate the 1-wei value, it has no practical farming value.

The pool only grows from donations and only shrinks from credit or GasClaim payouts — nothing is ever reimbursed for gas, and nothing locked in an offer can ever be reclaimed by its original donor.
