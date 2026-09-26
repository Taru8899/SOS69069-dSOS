```markdown
# SOS69069 dSOS

An ownerless, ETH-backed bearer-bond and credit-redemption mechanism built on top of the external **SOS69069** reputation ledger. dSOS does **not** issue a transferable ERC-20/721 token — `name()`/`symbol()` exist purely for wallet display. What it actually moves is ETH, locked and released through bonds and credits tied to signed records on the ledger.

Three ways to claim ETH from the pool exist side by side:

1. Redeeming a **common bond**
2. Redeeming a **directed bond**
3. Redeeming a **standalone credit** (no bond required)

All three are gated by the same movement-derived credit balance and the same eligibility window on the ledger's `effectiveOf()` score.

## Core constants & external dependency

| Constant | Value | Purpose |
|---|---|---|
| `SOS69069_LEDGER` | `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` | External ledger this deployment reads/writes (via `ISOS69069`) |
| `UNIT` | `0.000369 ether` | ETH locked per bond; ETH paid per redemption |
| `MIN_RESERVE` | `0.05 ether` | Floor on unearmarked ETH — never knowingly paid below this |
| `GAS_PER_CALLDATA_BYTE` | `16` | Calldata gas cost added to reimbursement (L1 rule) |
| `BASE_GAS_OVERHEAD` | `23,500` (placeholder) | Fixed gas overhead added to reimbursement — **must be calibrated against real deployed gas before mainnet deploy** |
| `MIN_EFFECTIVE` / `MAX_EFFECTIVE` | `-69069` / `+69069` | Bounds for both redemption eligibility and credit accounting |
| `CREDIT_STEP` | `100` | Points of accumulated movement required per credit |

SOS69069 itself has no transferable asset and rejects ETH outright — it only records signed messages and exposes live `Trust − Push` reputation counters. dSOS is the asset-bearing layer built on top of that ledger.

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
- Caller needs ≥1 credit and an eligible `effectiveOf()` score
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

## Credit system — cumulative absolute movement

Credits are earned from **total movement**, not net movement. Every call to `syncCredits` adds the full magnitude of change since the last sync into a running total; movement in opposite directions **adds together rather than canceling**.

```text
syncCredits(user):
  current = clamp(effectiveOf(user), -69069, +69069)
  Δ = |current − lastEffective[user]|
  total = movementRemainder[user] + Δ
  earned = total / 100
  movementRemainder[user] = total % 100      // leftover under 100, preserved
  lastEffective[user] = current              // always advances to current
  redemptionCredits[user] += earned
```

Example: effective moves +20, is synced, then moves -80, is synced again → `20 + 80 = 100` total movement → **1 credit earned**, even though the net change from start to finish was only -60.

**Important caveat**: this only correctly captures each individual move if `syncCredits` (or a redemption, which calls it internally) runs *between* changes. `effectiveOf()` only exposes the current value — if two changes happen with no sync in between, only their *net* effect is observable at the next sync.

- Callable by anyone, on any address, at any time — `syncCredits(user)`
- `pendingCredits(user)` previews the credit balance after a hypothetical sync, without writing state
- Credits never expire and are shared across **all three** redemption paths — spending one via `relay()` reduces what's available to `redeemCredit()`, and vice versa

## Redemption paths

**1. Bond relay / redeem — `relay(bondId, to, payloadHash, signature, metadata)`**
- Caller must be the bond's current holder
- Always writes a signed ledger record, atomically with any payout
- If `to` equals the bond's redeem target → redemption: syncs credits, checks eligibility range and credit balance, pays out, destroys the bond
- If `to` is any other address → forward: bond changes holder, no credit spent, no eligibility check
- Directed bonds: full `UNIT` from `totalEarmarked` + gas capped by pool headroom
- Common bonds: `UNIT` + gas both drawn from pool headroom, scaling proportionally if thin

**2. Standalone credit redemption — `redeemCredit(payloadHash, signature, metadata)`**
- No bond involved
- Requires ≥1 credit and an eligible `effectiveOf()` score
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
- Redemption requires both an eligible `effectiveOf()` score **and** a spendable movement-derived credit
- Every bond carries a `creationRecordHash` binding it to one specific, permanent ledger entry
- Payment and ledger record are always atomic — a failed ledger write reverts the whole transaction, so ETH can never move without a corresponding signed record
- Holder-bond indexing uses O(1) swap-and-pop removal

## Summary

Donors lock `0.000369 ETH` into bonds — common (shared redemption target) or directed (self-redemption, fully protected principal) — or simply top up the pool with plain ETH. Anyone's SOS69069 `effectiveOf()` score moving by 100 points, in any direction, earns 1 permanent, spendable credit; opposite-direction moves add up rather than offsetting. Those credits unlock ETH three ways: redeeming a common bond, redeeming a directed bond, or calling `redeemCredit()` with no bond at all — all backed by real ETH, all witnessed permanently on the SOS69069 ledger.
```