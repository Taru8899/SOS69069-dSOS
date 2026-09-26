# SOS69069 dSOS

A donation → mint entitlement → relay reward mechanism, backed by a single shared ETH pool.

**dSOS** is an ownerless, ETH-backed “bearer-bond” system that sits on top of the SOS69069 ledger. It does **not** issue a transferable ERC-20/721 token. Instead it mints ETH-locked bonds that can only be created and redeemed by writing signed records to the ledger. Credits for redemption are earned purely from movement in a user’s live `effectiveOf()` score on that ledger.

### Core constants & external dependency
- Ledger: `SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A` (immutable interface `ISOS69069`).
- Unit size: `UNIT = 0.000369 ether` (exact ETH locked per bond).
- Floor for common-bond redemptions: `MIN_RESERVE = 0.05 ether`.
- Gas overhead on redeem: `INTRINSIC_GAS = 21_000`.
- Redemption eligibility window: `effectiveOf(user) ∈ [-69069, 69069]`.
- Credit step: every 100 points of absolute movement in `effectiveOf` grants 1 non-expiring redemption credit.

### Two bond types
1. **Common bond** (`earmarked = false`)  
   - Creation record: `signer = msg.sender`, `intendedTo = SOS69069_LEDGER`.  
   - Redeem target is always the ledger address itself.  
   - Principal is drawn from the shared un-earmarked pool (subject to `MIN_RESERVE`).

2. **Directed bond** (`earmarked = true`)  
   - Creation record: `signer = msg.sender`, `intendedTo = mintTo` (the initial holder).  
   - Redeem target is **whoever currently holds the bond** (live `b.holder`).  
   - Principal is protected: `totalEarmarked` tracks the locked ETH; it is never available for common redemptions.

Every bond stores:
```solidity
struct Bond {
    address holder;          // current owner (can change via relay)
    bool    active;          // false after redemption
    bool    earmarked;       // directed vs common
    bytes32 creationRecordHash; // exact SOS69069 struct hash of the mint record
}
```

### Minting (donation)
All mint paths are payable and require a valid SOS69069 signature from `msg.sender`:

- `donateCommon(mintTo, payloadHash, signature, metadata)`  
  → records one signature to the ledger → mints one common bond to `mintTo`.

- `donateCommonBatch(...)` / `donateDirected(...)` / `donateDirectedBatch(...)`  
  → same logic, batch version uses the cheaper `recordSignatureOne`.

After the ledger write the contract computes `recordStructHash` and stores it on the bond. The ETH is simply held by the contract; directed bonds also increment `totalEarmarked`.

Plain ETH can also be sent via `receive()` (no bond minted).

### Credit system
Credits are earned by **movement**, not by absolute score:

```solidity
syncCredits(user):
  Δ = |currentEffective − lastCheckpoint|
  earned = Δ / 100
  credits += earned
  checkpoint advances by exactly earned × 100  // remainder is preserved
```

Anyone can call `syncCredits`.  
`pendingCredits(user)` is a pure view that shows what the balance would be after a sync.

### Relay / transfer / redeem
`relay(bondId, to, payloadHash, signature, metadata)` is the **only** way a bond can move or be redeemed. It is atomic with a ledger write:

1. Caller must be the current `holder`.
2. A signed record is always written: `signer = msg.sender`, `intendedTo = to`.
3. If `to == redeemTarget` (ledger for common, self for directed) → **redeem**:
   - Sync credits, check range `[-69069, 69069]`, require ≥ 1 credit.
   - Burn 1 credit, mark bond inactive, remove from holder list.
   - Compute gas reimbursement (`gasUsed + 21k) × tx.gasprice`.
   - **Directed**: pay full `UNIT` + as much gas as un-earmarked balance allows.
   - **Common**: pay up to `UNIT + gas` from `(balance − totalEarmarked − MIN_RESERVE)`.
   - Payout is proportional if the pool is insufficient.
4. Otherwise → **forward**: change `holder` to `to` (no credit or range check).

Because the ledger write and the ETH transfer happen in the same transaction, a redemption can never be separated from its signed record.

### Key invariants & safety
- No owner, no admin functions, no upgradeability.
- Directed principal is ring-fenced by `totalEarmarked`.
- Common redemptions never touch the earmarked pool or dip below `MIN_RESERVE`.
- Redemption is gated by both the effective-score window **and** a movement-derived credit.
- Every bond is cryptographically bound to a unique ledger entry via `creationRecordHash`.
- Holder lists are maintained with O(1) removal via index mapping.

In short: donors lock 0.000369 ETH and leave a signed SOS69069 record; holders can pass the bond around by writing further signed records; redemption consumes one credit (earned by moving one’s effective score by 100 points) and returns the locked ETH (plus gas) only when the bond is relayed to its proper redeem target.
