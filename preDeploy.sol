Here's the concrete workflow to calibrate `BASE_GAS_OVERHEAD` before you deploy for real — no guessing needed if you follow these steps.

## Step 1 — Deploy to a fork or testnet first

Never calibrate against a number you invented. Deploy the actual contract bytecode to either:
- A **local fork** of the target chain (Foundry's `anvil --fork-url <rpc>`, or Hardhat's forking mode), or
- A **public testnet** matching your deployment target (Sepolia for L1, or the L2's own testnet if you're deploying there).

The `SOS69069_LEDGER` dependency means you'll need either the real ledger deployed on that testnet, or a mock (like the `MockSOS69069` I sketched earlier) that mimics its interface with the same-shaped calldata.

## Step 2 — Set `BASE_GAS_OVERHEAD = 0` temporarily for measurement

Deploy a **calibration build** of the contract with `BASE_GAS_OVERHEAD` set to `0`. This way, whatever the contract *thinks* it used (`gasUsedMeasured`, already emitted in your `Redeemed`/`CreditRedeemed` events) reflects only the internal `gasStart - gasleft()` span, with nothing added — giving you a clean baseline to compare against reality.

## Step 3 — Call `relay()` and `redeemCredit()` for real, read the receipt

For each function, send a real transaction and pull two numbers:
1. **`receipt.gasUsed`** — the true total gas the transaction actually consumed (from the transaction receipt, via `ethers.js`, `web3.py`, or `cast receipt <txhash>` in Foundry).
2. **`gasUsedMeasured`** — read from the emitted event (`Redeemed.gasUsedMeasured` or `CreditRedeemed.gasUsedMeasured`), which is what the contract captured internally with the placeholder still at `0`.

```bash
# Foundry example
cast send $CONTRACT "redeemCredit(bytes32,bytes,string)" $HASH $SIG "test" --private-key $PK
cast receipt $TXHASH   # gives you receipt.gasUsed
cast logs --address $CONTRACT   # decode CreditRedeemed event for gasUsedMeasured
```

## Step 4 — Compute the real overhead

```
BASE_GAS_OVERHEAD_needed = receipt.gasUsed - gasUsedMeasured - (calldata_length * GAS_PER_CALLDATA_BYTE)
```

Since the calldata term is already handled separately in the formula, subtracting it out isolates exactly the leftover fixed cost — the tx base cost plus whatever runs after your internal measurement point (events, the ETH transfer).

Run this **several times**, ideally with different `metadata` string lengths (empty, short, near the 64-char max), to confirm the leftover number stays roughly constant across calls — if it does, that consistency confirms your calldata term is correctly absorbing the variable part, and whatever's left is your true fixed overhead.

## Step 5 — Add a safety margin, then hardcode it

Take the largest measured value across your test calls and add a small buffer (5–10%) to protect against minor EVM version differences or edge-case call patterns you didn't test. Set that as the final `BASE_GAS_OVERHEAD` constant in the contract you actually deploy to mainnet.

```solidity
uint256 public constant BASE_GAS_OVERHEAD = 24_800; // measured 22_950 + ~8% margin
```

## Step 6 — Re-verify on the real deployment

After deploying the calibrated version, run one more real `relay()`/`redeemCredit()` call and compare `principalPaid + gasPaid` against the actual gas cost the caller paid (`receipt.gasUsed * receipt.effectiveGasPrice`). They should now be very close — a few percent apart at most, from your safety margin, not tens of percent off like the original flat `21_000` guess would have been.

**One structural note**: since there's no admin/upgrade path in this contract, this calibration has to happen *before* the version you actually deploy — once it's live, `BASE_GAS_OVERHEAD` is frozen forever at whatever you picked in Step 5.