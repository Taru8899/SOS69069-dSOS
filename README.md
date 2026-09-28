# SOS69069 dSOS

An ownerless ETH contract with two independent mechanisms, both gated by real signed records on the external **SOS69069** reputation ledger:

1. **Directed bonds** — transferable bearer claims on a fixed ETH amount, always redeemable back to their original donor.
2. **Common pool credits** — a donation pool, drawn down only by earning and spending credits from ledger activity.

dSOS does not issue a transferable ERC-20/721 token — `name()`/`symbol()` exist purely for wallet display.

## Core constants

| Constant | Value | Purpose |
|---|---|---|
| `SOS69069_LEDGER` | `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` | External ledger this deployment reads/writes |
| `UNIT` | `0.000369 ether` | Flat payout per credit redemption |
| `MIN_RESERVE` | `0.000999 ether` | Floor the common pool must stay above after any credit redemption |
| `MIN_EFFECTIVE` / `MAX_EFFECTIVE` | `-69069` / `+69069` | Eligibility window on `effectiveOf()`, required for **both** redemption paths |
| `MIN_ACTIVITY` | `1000` | Minimum lifetime `pushCount + trustCount` required to redeem a credit |

SOS69069 itself has no transferable asset and rejects ETH outright — it only records signed messages and exposes live `Push`, `Trust`, and `effectiveOf() = Trust − Push` counters.

## Directed bonds

```solidity
struct Bond {
    address holder;             // current holder — transferable
    uint96  principal;          // ETH locked (any amount up to uint96)
    address donor;              // original funder — permanent, never changes
    bool    active;             // false once redeemed
    uint64  index;              // position in bondsHeldBy[holder]
    bytes32 recordHash;         // exact SOS69069 struct hash of the mint record
}
```

**Creating a bond — `donateDirected(to, payloadHash, signature, metadata)`**
- Donor sends **any ETH amount** (nonzero, ≤ `type(uint96).max`) in a single call.
- Writes one signed record: `donor → to`.
- One bond is created for the full amount.
- `to` **may equal the donor** (self-bond is allowed).
- `totalEarmarked` increases by the sent amount, ring-fencing it from the common pool.

**Transferring — `transferBond(bondId, to, payloadHash, signature, metadata)`**
- Only the current holder may call.
- Writes a signed record: `currentHolder → to`.
- `holder` updates; `donor` and `principal` never change; the bond stays active.
- **A bond can never be transferred to its original donor** (`DonorCannotHold`).
- Can be repeated any number of times — a bond may pass through many hands before redemption.

**Redeeming — `redeemDirected(bondId, payloadHash, signature, metadata)`**
- Only the current holder may call.
- Requires `effectiveOf(holder)` within `[-69069, +69069]`.
- Writes a signed record targeting the bond’s **original donor** — regardless of how many transfers happened in between.
- Pays the **current holder** the full `principal`, in full, always — never scaled down, never capped by pool health (paid from the bond’s own ring-fenced ETH).
- `totalEarmarked` decreases by `principal`; the bond is marked inactive permanently.

**Example flow**: A creates a bond with 1 ETH to B (record: A→B). B transfers to C (record: B→C). C transfers to D (record: C→D). D redeems (record: D→A). D receives the full 1 ETH.

## Common pool — donation only, no individual claims

- `donateCommon(payloadHash, signature, metadata)`: donor sends any ETH amount, writes a record `donor → SOS69069_LEDGER`, and the ETH joins the shared pool. **No bond is minted** — this is a non-redeemable donation.
- Plain ETH sent via `receive()` also joins the pool, with no record and no bond.
- `commonPool()` = contract balance minus `totalEarmarked` — the pool never includes ETH backing an active directed bond.

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

- **Only increases in `trustCountOf()`** produce credits. Push records earn nothing.
- This design ensures that a credit redemption’s own ledger record (which raises the caller’s Push) cannot itself mint a new credit.
- No weighting, no conversion ratio, no remainder — every new trust record earns exactly 1 credit.
- Callable by anyone, on any address, at any time via `syncCredits(user)`. `pendingCredits(user)` previews the result without writing state.

## Redeeming a credit — `redeemCredit(payloadHash, signature, metadata)`

All four conditions must hold, or the call reverts before any state changes:
- `redemptionCredits[caller] ≥ 1` (after an internal sync)
- `effectiveOf(caller)` within `[-69069, +69069]`
- Lifetime `pushCountOf(caller) + trustCountOf(caller) ≥ 1000`
- `commonPool() ≥ MIN_RESERVE + UNIT` — paying out must not drop the pool below its floor

On success: 1 credit is burned, a signed record `caller → SOS69069_LEDGER` is written, and the caller is paid a flat `0.000369 ETH`. No gas reimbursement.

## Atomicity — the core guarantee

Every state-changing function follows the same pattern: **local state is fully updated first, then the external ledger call happens, then (for redemptions) ETH is sent.** If `SOS.recordSignature(...)` reverts for any reason — invalid signature, duplicate record, wrong signer — the entire transaction reverts, undoing every state change made earlier in that same call. There is no path where a bond is marked redeemed, a credit is spent, or ETH leaves the contract without a corresponding successful signed record landing on the SOS69069 ledger in that same transaction.

## Safety

- `nonReentrant` guard on every state-changing function (`donateDirected`, `transferBond`, `redeemDirected`, `redeemCredit`).
- All local state finalized *before* the external `recordSignature` call in every function.
- `totalEarmarked` is only ever incremented in `donateDirected` and decremented in `redeemDirected` — `transferBond` never touches it.
- `commonPool()` always excludes `totalEarmarked`, so directed-bond principal can never be reached through `redeemCredit`.
- No owner, no admin functions, no upgradeability, no pause switch.
- Principal stored as `uint96`, counters as `uint128` for tight packing.
- A bond can never be transferred to its original donor.

## Views

| Function | Returns |
|---|---|
| `commonPool()` | ETH available for credit redemption (balance minus earmarked) |
| `poolBalance()` | Total contract ETH balance |
| `isEligible(user)` | True iff `user` currently passes every `redeemCredit` gate (except live pool balance) |
| `signerMetrics(user)` | Raw `push`, `trust`, `effective` values from the ledger |
| `pendingCredits(user)` | Live credit balance as of a hypothetical sync now |
| `bondCountOf(holder)` / `bondIdsOf(holder)` | Bonds currently held by an address |
| `bonds(bondId)` | Full bond details (donor, holder, principal, active, creationRecordHash) |
| `lastTrust(user)` / `redemptionCredits(user)` | Raw account storage |

## Summary

A donor locks any amount of ETH into a directed bond addressed to someone (including themselves); that bond can change hands freely (but never back to the original donor), and always settles back to the original donor’s address on the ledger when finally redeemed, paying whoever holds it at that moment the full amount. Separately, anyone can top up a shared donation pool, and every new **trust** record anyone earns on SOS69069 becomes a spendable credit — redeemable for a flat `0.000369 ETH`, as long as the holder’s reputation sits within range, they’ve built up enough lifetime activity, and the pool can absorb the payout without dropping below its reserve.
```