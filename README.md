SOS69069 dSOS

### Identity
- Name: **"SOS69069 dSOS"**, Symbol: **"dSOS"**.
- `SOS69069_LEDGER` pinned to `0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A`, immutable.

### Constants
- `UNIT = 0.000369 ether` — baseline mode 0 price floor.
- **`MIN_RESERVE = 0.000999 ether`** (updated) — applied **independently per mode pool**, not once globally.
- `MIN_EFFECTIVE = -69069`, `MAX_EFFECTIVE = 69069` — anti-hoarding gate, unchanged.
- `CREDIT_STEP = 100`, `PUSH_WEIGHT = 1`, `TRUST_WEIGHT = 1` — credit-earning, unchanged.
- `GAS_PER_CALLDATA_BYTE = 16`, `BASE_GAS_OVERHEAD = 23,500` (placeholder, needs calibration) — gas reimbursement, unchanged.

### Modes
- A mode is a pair: **`(unit, records)`**.
  - `unit` — ETH locked at mint / paid at redemption for this mode.
  - `records` — a comparative percentage-vs-baseline label only; no computational role in redemption.
- **Mode 0 (baseline)**: `unit = 0.000369 ETH`, `records = 100` (= 100% reference), created in the constructor.
- **Creating a mode**: `createMode(unit, records)` — permissionless, callable by anyone, anytime.
  - `unit >= UNIT` (`>= 0.000369 ether`).
  - `records >= 100`.
  - No upper bound on either.
  - Immutable once created — no edit, no removal.
  - Each mode gets a unique, incrementing `modeId` and its **own isolated pool**, starting at zero.
- **Every mode, regardless of `records`, always costs exactly 1 credit to redeem.**

### Per-mode pool separation
- `mapping(uint256 => uint256) public modeCommonPool` — each mode's own ETH balance, fully isolated from every other mode.
- **Common-bond donations under mode X** credit only `modeCommonPool[X]`.
- **Common-bond redemptions and `redeemCredit(modeId, ...)` under mode X** draw only from `modeCommonPool[X]` — never another mode's pool, never a blended total.
- **`MIN_RESERVE = 0.000999 ETH` applies independently per mode**: `modeHeadroom(modeId) = max(modeCommonPool[modeId] − MIN_RESERVE, 0)`. Every mode maintains its own floor; a thin mode cannot borrow headroom from a flush one.
- **Plain `receive()` ETH always and only credits `modeCommonPool[0]`** (baseline). There is no way to plain-send ETH into any other mode's pool — the only way to fund a non-baseline mode's pool is via `donateCommon`/`donateCommonBatch` under that specific `modeId`, which always mints a bond as part of the transaction.

### Directed bonds — unaffected by pool separation, except gas source
- Directed-bond **principal** remains ring-fenced in the single global `totalEarmarked`, always paid in full, completely independent of any mode pool's balance.
- Directed-bond **gas reimbursement** draws from **the same mode's pool the bond was minted under** — `modeCommonPool[bond.modeId]`, capped at that mode's own headroom (option b, confirmed).

### Bonds
```solidity
struct Bond {
    address holder;
    bool active;
    bool earmarked;
    bytes32 creationRecordHash;
    uint256 modeId;
    uint256 principal; // = modes[modeId].unit at mint time
}
```

### Minting
- `donateCommon(modeId, mintTo, payloadHash, signature, metadata)` — 1 common bond; `msg.value == modes[modeId].unit`; credits `modeCommonPool[modeId]`.
- `donateCommonBatch(modeId, mintTo, count, payloadHashes[], signatures[], metadatas[])` — `count` common bonds, one recipient; `msg.value == modes[modeId].unit * count`; all credited to `modeCommonPool[modeId]`.
- `donateDirected(modeId, mintTo, payloadHash, signature, metadata)` — 1 directed bond; `msg.value == modes[modeId].unit`; added to global `totalEarmarked`.
- `donateDirectedBatch(modeId, mintTo, count, payloadHashes[], signatures[], metadatas[])` — same pattern, batched.
- All four require a valid donor signature; not gas-sponsored.

### Credit-earning — unchanged, mode-agnostic
- `syncCredits(user)`: weighted push/trust deltas since last sync, `CREDIT_STEP = 100`, `PUSH_WEIGHT`/`TRUST_WEIGHT = 1`, remainder carried forward, no-op if no change.
- One shared `redemptionCredits[user]` balance, spendable against any mode or bond type.
- Callable by anyone, anytime.

### Redemption
**1. `relay(bondId, to, payloadHash, signature, metadata)`**
- Mode read from `bonds[bondId].modeId`.
- Redemption requires: `syncCredits(caller)`, `redemptionCredits[caller] >= 1`, `effectiveOf(caller)` within `[-69069, +69069]`.
- Directed bond: principal in full from `totalEarmarked`; gas from `modeCommonPool[bond.modeId]` headroom.
- Common bond: principal + gas both from `modeCommonPool[bond.modeId]`, scaled proportionally if thin; reverts if `principalPaid < bond.principal / 2`.
- Forward (no redemption): bond changes holder, no credit/eligibility check.

**2. `redeemCredit(modeId, payloadHash, signature, metadata)`**
- No bond; caller picks `modeId` explicitly.
- Same credit/eligibility checks.
- Pays `modes[modeId].unit` (+ gas) from `modeCommonPool[modeId]` exclusively, scaled if thin; reverts if `principalPaid < modes[modeId].unit / 2`.

### Pool accounting
```
contract balance = totalEarmarked                          (directed bonds, all modes, ring-fenced)
                  + Σ modeCommonPool[i] for every mode i    (each mode's own isolated pool)
```
Each `modeCommonPool[i]` independently maintains its own `0.000999 ETH` reserve floor.

### Chain ID
- Not settable per-record; fixed permanently in the SOS69069 ledger's own EIP-712 domain separator at its deployment. dSOS forwards signatures as-is.

### Known open items (carried forward, unresolved by earlier instruction)

- First-sync retroactive credit (`lastPush`/`lastTrust` default to 0) — left as-is.
- `PUSH_WEIGHT == TRUST_WEIGHT == 1` — confirmed intentional, immutable.

### Invariants
- No owner, no admin, no upgradeability, no pause switch.
- Modes immutable once created, each with an isolated pool from inception.
- Directed-bond principal always fully protected in the single global `totalEarmarked`.
- Every common-pool redemption path (bond or standalone) draws only from its own specific mode's pool — never blended, never cross-subsidized.
- Plain `receive()` ETH always and only funds mode 0's pool.
- `MIN_RESERVE = 0.000999 ETH` enforced independently, per mode.
- Redemption always requires both a spendable credit and an in-range `effectiveOf()` score.
- Payment and ledger record remain atomic across every path.
