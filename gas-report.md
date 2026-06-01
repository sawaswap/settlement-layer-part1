# Gas Report — Settlement Layer (Part 1)

Gas usage for all Part 1 protocol actions per §C.3.6 / §D.2.4 D11. Measurements drawn from:

1. **`forge test --gas-report`** on the M2 test suite (70 unit + integration tests at `4326a80`), which exercises every Part 1 entry point through min / median / max gas paths.
2. **Live measurements** from the canonical `--broadcast` on Base Sepolia (chain 84532) on 2026-05-28, using `cast receipt` against the deploy transactions of the canonical instance at Settlement [`0x9645827808E25b4e19B1B8A05B075606dfF86331`](https://sepolia.basescan.org/address/0x9645827808E25b4e19B1B8A05B075606dfF86331) (deploy txs linked below). Pre-canonical dev measurements during PR #10 preparation matched canonical to within a few gas (handful-of-bytes calldata difference); the figures below are the canonical record.

Compiler: `solc 0.8.24` with `optimizer = true` / `optimizer_runs = 200` / `via_ir = false`. Compiler-flag changes can shift these numbers measurably; reproduce by checking out the same commit and running `forge test --gas-report` from a clean clone (§D.3.3).

---

## 1. Deployment cost

The canonical M3 deploy is two on-chain contracts: `MockDRP` (frozen-interface DRP stub per §C.3.7) and `Settlement` (the Part 1 contract). USDC is the Circle-issued Base Sepolia testnet token at `0x036CbD53842c5426634e7929541eC2318f3dCF7e` and is not deployed by the canonical script — it already exists on chain.

| Contract | Live gas used (canonical, Base Sepolia) | Deployment size (runtime bytecode) | Deploy tx hash |
|---|---:|---:|---|
| `MockDRP` | 221,812 | 809 bytes | [`0x0d1d575d…`](https://sepolia.basescan.org/tx/0x0d1d575d3d9273a297f94d130aa13790cf31f745e7a9cbf5e52c7f6f42b4d3dc) |
| `Settlement` | 2,153,682 | 10,336 bytes | [`0x38999636…`](https://sepolia.basescan.org/tx/0x38999636d3f352b592b1e3c46e0070418e710ea45b270f56712e17c66e18e1b4) |
| **Canonical total** | **2,375,494** | — | — |

Both canonical txs landed in the same block (`42110394`) at an effective gas price of **0.006 gwei**, paying **0.0000143 ETH** total across the two deploys. USDC is the Circle-issued Base Sepolia testnet token (already on chain) and is not deployed by the canonical script.

---

## 2. Per-function gas

From the M2 test suite under `forge test --gas-report`. The `min` column captures revert paths (typical ~28k); the `max` column captures the deepest happy paths including state transitions, event emissions, and escrow movement; `median` is the practical typical use.

| Function | Min (revert) | Median | Max (happy / terminal) | Notes |
|---|---:|---:|---:|---|
| `commitPoI` | 28,000 | 276,029 | 276,041 | Includes `safeTransferFrom` escrow pull + STID derivation + storage of full `Transaction` struct + event emit |
| `submitPoR` | 29,594 | 35,507 | 119,765 | Max path includes `_finalizeSettled` (state to `Settled` + escrow release to beneficiary) |
| `pokeTW1` | 28,786 | 52,931 | 52,931 | State transition `PoICommitted → EscalationL1` (permissionless) |
| `submitClaim` | 29,617 | 58,172 | 80,463 | Includes `_expireTW1IfDue` auto-escalate + claim-hash storage |
| `updateClaim` | 29,642 | 35,607 | 40,458 | Claim-hash update; bounded to pre-`invokeDRP` per TW2 |
| `invokeDRP` | 28,851 | 38,355 | 109,527 | Max path includes external DRP call + atomic `_finalizeSettled` or `_finalizeReversed` |
| `expireTW2` | 28,787 | 46,198 | 76,363 | Max path includes `_finalizeReversed` (escrow return to originator) |
| `expireTW3` | 28,787 | 33,534 | 56,729 | Max path includes `_finalizeReversed` (TW3 default-reverse per the 23 May ratified §C.3.8(a) remediation) |
| `setDefaultTimeWindows` | 24,532 | 28,160 | 31,810 | Admin-only |
| `setRailPairProfile` | 48,591 | 48,591 | 48,591 | Admin-only |
| Getters (`getTransaction`, `getDefaultTimeWindows`, `transactionExists`, etc.) | ~2,500–21,300 | — | — | View functions; gas only billed against external static-calls |

Internal helpers (`_finalizeSettled`, `_finalizeReversed`, `_expireTW1IfDue`, `_settleEscrow`) are not directly callable; their cost is folded into the externals above. `settle` / `reverse` are M1-era ABI placeholders that revert with `NotImplementedM1()` at ~370 gas — retained for ABI stability per the 15 May external-recovery-hatch dismissal.

---

## 3. USD cost estimates

Base mainnet gas prices and ETH/USD vary continuously; the figures below are illustrative at the time of writing (2026-05-27) and should be re-evaluated at acceptance time.

**Assumptions:**

- Base mainnet typical gas price: **0.05 gwei** (Base is L2; gas is ~1000× cheaper than ETH mainnet at peak; 0.05 gwei is a comfortable upper bound for non-peak operations).
- ETH / USD: **$3,500** (illustrative reference; substitute spot at acceptance time).

| Action | Gas | ETH @ 0.05 gwei | USD @ $3,500 / ETH |
|---|---:|---:|---:|
| Canonical deploy (MockDRP + Settlement) | 2,375,506 | 0.000119 | $0.42 |
| `commitPoI` (median) | 276,029 | 0.0000138 | $0.048 |
| `submitPoR` → `Settled` (max) | 119,765 | 0.0000060 | $0.021 |
| `pokeTW1` (TW1 escalation) | 52,931 | 0.0000026 | $0.0093 |
| `submitClaim` (max) | 80,463 | 0.0000040 | $0.014 |
| `updateClaim` (max) | 40,458 | 0.0000020 | $0.0071 |
| `invokeDRP` → terminal (max) | 109,527 | 0.0000055 | $0.019 |
| `expireTW2` → `Reversed` (max) | 76,363 | 0.0000038 | $0.013 |
| `expireTW3` → `Reversed` (max) | 56,729 | 0.0000028 | $0.0099 |

**End-to-end transaction lifecycle cost (worst-case happy path):**

- CMM happy path (`commitPoI` → `submitPoR` → `Settled`): 276,041 + 119,765 = **395,806 gas** → ~$0.069 at the assumptions above.
- Escalated DRP path (`commitPoI` → `pokeTW1` → `submitClaim` → `invokeDRP` → terminal): 276,041 + 52,931 + 80,463 + 109,527 = **518,962 gas** → ~$0.091.
- Default-reverse path (`commitPoI` → `pokeTW1` → `expireTW2` → `Reversed`): 276,041 + 52,931 + 76,363 = **405,335 gas** → ~$0.071.

**On Base Sepolia testnet** the same operations cost roughly **0.006 / 0.05 = 12% of the figures above in gas-spent ETH**, and the asset itself has no value — included for completeness only.

---

## 4. Reproducibility

To regenerate this report from a clean clone of the repository:

```bash
git clone <repo>; cd <repo>
git submodule update --init --recursive
forge test --gas-report --no-match-path "test/invariants/*"
```

The `forge test --gas-report` output prints a per-function gas table for `src/Settlement.sol:Settlement` and the deployment cost line; cross-reference against §2 above.

For live measurements, the deploy txs on Base Sepolia are linked in §1; alternatively, run `script/DeployDev.s.sol` from your own funded test wallet to produce fresh deploy-cost numbers under current network gas prices.
