**SOS69069 dSOS**

A donation → mint entitlement → relay / credit-redemption mechanism, backed by a single shared ETH pool.

dSOS is an ownerless, ETH-backed system that sits on top of the SOS69069 ledger. It does **not** issue a transferable ERC-20/721 token. Instead it supports two parallel ways to claim ETH from the common pool, both gated by the same movement-derived credits:

1. Redeeming a specific **Bond** object  
2. Redeeming a **standalone credit** directly (no bond required)

Credits are earned purely from movement in a user’s live `effectiveOf()` score on the SOS69069 ledger.

### Core constants & external dependency

- **Ledger**: `SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` (immutable interface `ISOS69069`)
- **Unit size**: `UNIT = 0.000369 ether` (ETH paid out per successful claim)
- **Floor for common-pool draws**: `MIN_RESERVE = 0.05 ether`
- **Gas accounting**:
  - `BASE_GAS_OVERHEAD = 23_500` (fixed overhead, placeholder – calibrate before mainnet)
  - `GAS_PER_CALLDATA_BYTE = 16`
- **Redemption eligibility window**: `effectiveOf(user) ∈ [-69069, 69069]`
- **Credit step**: every 100 points of absolute movement in `effectiveOf` grants 1 non-expiring redemption credit

### Two bond types + one bond-less path

**Common bond** (`earmarked = false`)
- Creation record: `signer = msg.sender`, `intendedTo = SOS69069_LEDGER`
- Redeem target is always the ledger address
- Principal is drawn from the shared un-earmarked pool (subject to `MIN_RESERVE`)
- Consumes 1 credit

**Directed bond** (`earmarked = true`)
- Creation record: `signer = msg.sender`, `intendedTo = mintTo`
- Redeem target is whoever currently holds the bond (self)
- Principal is protected by `totalEarmarked` and is always paid in full
- Consumes 1 credit
- Unaffected by the new standalone path

**Standalone credit redemption** (new)
- No Bond object required
- Caller must have ≥ 1 credit and be inside the effective range
- Writes a ledger record targeting `SOS69069_LEDGER`
- Draws `UNIT` + gas reimbursement from the same common pool used by common-bond redemptions
- Consumes 1 credit from the shared balance

Every bond stores:

```solidity
struct Bond {
    address holder;             // current owner (can change via relay)
    bool    active;             // false after redemption
    bool    earmarked;          // directed vs common
    bytes32 creationRecordHash; // exact SOS69069 struct hash of the mint record
}
```

### Minting (donation)

All mint paths are payable and require a valid SOS69069 signature from `msg.sender`:

- `donateCommon` / `donateCommonBatch` → common bonds
- `donateDirected` / `donateDirectedBatch` → directed bonds

After the ledger write the contract stores the exact `recordStructHash` on the bond. Directed bonds also increment `totalEarmarked`.

Plain ETH can still be sent via `receive()` (no bond minted). This ETH joins the common pool and can be claimed by either common-bond holders or standalone credit redeemers.

### Credit system

Credits are earned by **movement**, not by absolute score:

```text
syncCredits(user):
  Δ = |currentEffective − lastCheckpoint|
  earned = Δ / 100
  credits += earned
  checkpoint advances by exactly earned × 100   // remainder is preserved
```

- Anyone can call `syncCredits`
- `pendingCredits(user)` shows the balance after a hypothetical sync
- The same credit balance is shared between:
  - common-bond redemption via `relay()`
  - standalone redemption via `redeemCredit()`

### Redemption paths

**1. Bond relay / redeem** (`relay`)

- Caller must be the current holder
- Always writes a signed record
- If `to` equals the redeem target → redeem (consumes 1 credit)
- Directed bonds pay full `UNIT` from `totalEarmarked` + gas from the common pool
- Common bonds pay from the common pool (proportional if thin)
- Otherwise the bond is simply forwarded to a new holder

**2. Standalone credit redemption** (`redeemCredit`)

- No bond needed
- Requires 1 credit + effective score in range
- Writes a ledger record to `SOS69069_LEDGER`
- Pays `UNIT` + gas from the common pool (same rules as common-bond redemption)
- Atomic with the ledger write

Both common-bond and standalone paths use the identical `_payFromCommonPool` logic and respect `MIN_RESERVE`.

### Key invariants & safety

- No owner, no admin functions, no upgradeability
- Directed principal is ring-fenced by `totalEarmarked`
- Common-pool draws (both bond and standalone) never touch earmarked funds or go below `MIN_RESERVE`
- Redemption is gated by the effective-score window **and** a movement-derived credit
- Every bond is cryptographically bound to a unique ledger entry via `creationRecordHash`
- Holder lists use O(1) removal
- Payment and ledger record are atomic — they cannot be separated

### Summary

Donors can lock 0.000369 ETH into bonds (or simply donate ETH to the common pool).  
Users earn credits by moving their SOS69069 `effectiveOf` score.  
Those credits can be spent in two ways against the common pool:

- by redeeming a specific common bond they hold, or  
- by calling `redeemCredit` with no bond at all.

Directed bonds remain fully protected and can only be redeemed by their current holder.
