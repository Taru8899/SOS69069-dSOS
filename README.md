# SOS69069 dSOS

An ownerless, ETH-backed bearer-bond and credit-redemption mechanism built on top of the external **SOS69069** reputation ledger. dSOS does **not** issue a transferable ERC-20/721 token — `name()`/`symbol()` exist purely for wallet display. What it actually moves is ETH, locked and released through bonds and credits tied to signed records on the ledger.

Three ways to claim ETH from the pool exist side by side:

1. Redeeming a **common bond**
2. Redeeming a **directed bond**
3. Redeeming a **standalone credit** (no bond required)

All three require **both** a spendable credit **and** a live anti-hoarding check on the ledger's `effectiveOf()` score.

## Core constants & external dependency

| Constant | Value | Purpose |
|---|---|---|
| `SOS69069_LEDGER` | `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` | External ledger this deployment reads/writes (via `ISOS69069`) |
| `UNIT` | `0.000369 ether` | ETH locked per bond; ETH paid per redemption |
| `MIN_RESERVE` | `0.05 ether` | Floor on unearmarked ETH — never knowingly paid below this |
| `GAS_PER_CALLDATA_BYTE` | `16` | Calldata gas cost added to reimbursement (L1 rule) |
| `BASE_GAS_OVERHEAD` | `23,500` (placeholder) | Fixed gas overhead added to reimbursement — **must be calibrated against real deployed gas before mainnet deploy** |
| `MIN_EFFECTIVE` / `MAX_EFFECTIVE` | `-69069` / `+69069` | Anti-hoarding window on `effectiveOf()` — enforced as an independent redemption gate |
| `CREDIT_STEP` | `100` | Weighted activity units required per redemption credit |
| `PUSH_WEIGHT` | `1` | Weight of each unit of push-count increase |
| `TRUST_WEIGHT` | `1` | Weight of each unit of trust-count increase |

SOS69069 itself has no transferable asset and rejects ETH outright — it only records signed messages and exposes live `Push`, `Trust`, and `effectiveOf() = Trust − Push` counters. dSOS is the asset-bearing layer built on top of that ledger.

## Bond types

Every bond is stored as:

```solidity
struct Bond {
    address holder;             // current owner (changes via relay)
    bool    active;             // false once redeemed
    bool    earmarked;          // true = directed, false = common
    bytes32 creationRecordHash; // exact SOS69069 struct hash of the mint record
}
```

**Common bond** (`earmarked = false`)
- Creation record: `signer = donor`, `intendedTo = SOS69069_LEDGER`
- Redeem target: the contract itself (relay a bond to `SOS69069_LEDGER` to cash it out)
- Principal drawn from the shared, un-earmarked pool — can scale down proportionally if the pool is thin
- Consumes 1 redemption credit

**Directed bond** (`earmarked = true`)
- Creation record: `signer = donor`, `intendedTo = mintTo` (the recipient itself)
- Redeem target: whoever currently holds the bond (self-redemption)
- Principal is ring-fenced in `totalEarmarked` and **always paid in full**, regardless of pool health
- Only the gas-reimbursement portion can be capped if unearmarked funds are thin
- Consumes 1 redemption credit

**Standalone credit redemption** — no bond object at all
- Caller needs ≥1 credit and must pass the anti-hoarding range check
- Writes a record targeting `SOS69069_LEDGER`, exactly like a common-bond redemption
- Draws `UNIT` + gas from the same common pool, and spends from the **same shared credit balance** as bond-based redemption

## Minting (donation)

All four mint functions are `payable` and require the donor (`msg.sender`) to supply a valid ECDSA signature, since the contract calls the ledger's `recordSignature`/`recordSignatureOne` on the donor's behalf:

- `donateCommon(mintTo, payloadHash, signature, metadata)` — 1 common bond
- `donateCommonBatch(mintTo, count, payloadHashes[], signatures[], metadatas[])` — `count` common bonds, one recipient
- `donateDirected(mintTo, payloadHash, signature, metadata)` — 1 directed bond
- `donateDirectedBatch(mintTo, count, payloadHashes[], signatures[], metadatas[])` — `count` directed bonds, one recipient

Each bond's `creationRecordHash` is captured via `recordStructHash` right after the ledger write, permanently tying that bond to one exact ledger entry. Directed mints add to `totalEarmarked` immediately.

Plain ETH sent via `receive()` mints nothing — it simply tops up the common pool, benefiting both common-bond redeemers and standalone credit redeemers.

## Credit system — weighted push/trust activity, not net score

Credits no longer come from movement in the net `effectiveOf()` score. They come from **independent increases in the two raw ledger counters** — `pushCountOf()` and `trustCountOf()` — each weighted separately and summed:

```text
syncCredits(user):
  currentPush  = pushCountOf(user)
  currentTrust = trustCountOf(user)
  pushDelta    = max(currentPush  - lastPush[user],  0)
  trustDelta   = max(currentTrust - lastTrust[user], 0)

  if pushDelta == 0 and trustDelta == 0: return   // no state write, no event

  weighted = pushDelta * PUSH_WEIGHT + trustDelta * TRUST_WEIGHT
  total    = activityRemainder[user] + weighted
  earned   = total / CREDIT_STEP
  activityRemainder[user] = total % CREDIT_STEP   // leftover under 100, preserved
  lastPush[user]  = currentPush
  lastTrust[user] = currentTrust
  redemptionCredits[user] += earned
```

With `PUSH_WEIGHT = TRUST_WEIGHT = 1`: **60 push + 40 trust since the last sync = 100 weighted units = 1 credit**, regardless of what that does to the net `effectiveOf()` score. Since both `Push` and `Trust` only ever increase on the real ledger, every signed record involving a user — whether it made them look more or less trustworthy net — contributes positively toward credits.

- Callable by anyone, on any address, at any time — `syncCredits(user)`
- `pendingCredits(user)` previews the credit balance after a hypothetical sync, without writing state
- Credits never expire and are shared across **all three** redemption paths — spending one via `relay()` reduces what's available to `redeemCredit()`, and vice versa
- `CreditsSynced` now reports the user's raw `pushCount`/`trustCount` at sync time (instead of a net effective value), alongside earned and total credits

## Anti-hoarding window — a separate, independent gate

Regardless of how many credits a user has earned, **redemption is blocked unless `effectiveOf(user)` currently sits within `[-69069, +69069]`.** This check is completely decoupled from the credit system above — it doesn't affect how credits are earned or spent, it's purely a live ceiling/floor on net reputation that must also be satisfied at the moment of redemption.

```text
isEligible(user) = pendingCredits(user) > 0  AND  effectiveOf(user) in [-69069, +69069]
```

A user can accumulate unlimited credits from push/trust activity, but cannot cash any of them in while their net effective score has drifted outside this window.

## Redemption paths

**1. Bond relay / redeem — `relay(bondId, to, payloadHash, signature, metadata)`**
- Caller must be the bond's current holder
- Always writes a signed ledger record, atomically with any payout
- If `to` equals the bond's redeem target → redemption: syncs credits, requires ≥1 credit **and** `effectiveOf()` within range, pays out, destroys the bond
- If `to` is any other address → forward: bond changes holder, no credit or range check
- Directed bonds: full `UNIT` from `totalEarmarked` + gas capped by pool headroom
- Common bonds: `UNIT` + gas both drawn from pool headroom, scaling proportionally if thin

**2. Standalone credit redemption — `redeemCredit(payloadHash, signature, metadata)`**
- No bond involved
- Requires ≥1 credit **and** `effectiveOf()` within range
- Writes a record to `SOS69069_LEDGER`, atomically with payout
- Pays `UNIT` + gas from the same pool headroom as common-bond redemption

Both common-bond and standalone paths share identical payout math (`_payFromCommonPool`) and the identical `MIN_RESERVE` floor.

## Gas reimbursement

Every redemption reimburses the caller's gas: `(measured internal gas + calldata cost of the call + BASE_GAS_OVERHEAD) × tx.gasprice`.

- Calldata cost is computed live from `msg.data.length`, so it scales correctly with signature/metadata size
- `BASE_GAS_OVERHEAD` is a fixed placeholder covering the tx base cost and post-measurement opcodes (events, the ETH transfer) — **calibrate this against real deployed gas usage before mainnet deployment**; it cannot be changed afterward
- Gas reimbursement for **every** redemption path (common, directed, and standalone) is capped by the same pool headroom (`unearmarked − MIN_RESERVE`) — a wave of redemptions can never drain unearmarked funds below the reserve through gas payouts alone
- Directed-bond **principal** is the one exception: always paid in full from `totalEarmarked`, untouched by `MIN_RESERVE`

## Key invariants & safety

- No owner, no admin functions, no upgradeability, no pause switch
- Directed-bond principal is permanently ring-fenced in `totalEarmarked`, unreachable by any other redemption
- `MIN_RESERVE` protects unearmarked funds from every path's gas reimbursement, not just common-bond payouts
- Redemption requires **both** a spendable weighted-activity credit **and** an in-range `effectiveOf()` score — two independent gates, not one
- Every bond carries a `creationRecordHash` binding it to one specific, permanent ledger entry
- Payment and ledger record are always atomic — a failed ledger write reverts the whole transaction, so ETH can never move without a corresponding signed record
- Holder-bond indexing uses O(1) swap-and-pop removal

## Summary

Donors lock `0.000369 ETH` into bonds — common (shared redemption target) or directed (self-redemption, fully protected principal) — or simply top up the pool with plain ETH. Every increase in a user's `pushCountOf()` or `trustCountOf()` on the SOS69069 ledger, weighted equally, accumulates toward a permanent, spendable credit every 100 weighted units. Those credits unlock ETH three ways — redeeming a common bond, redeeming a directed bond, or calling `redeemCredit()` with no bond at all — but only while the user's net `effectiveOf()` score stays within `[-69069, +69069]`, an independent anti-hoarding ceiling that applies regardless of credit balance.
```