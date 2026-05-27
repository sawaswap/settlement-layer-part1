# DEPLOYMENT.md — Settlement Layer (Part 1) deploy guide

This document is the step-by-step guide for the canonical Base Sepolia deployment of `Settlement.sol` under §D.2.4 (M3 — Testnet Deployment + Handover) of the engagement contract. It is written so that a competent third party who has not interacted with the Developer can read the repository, install the environment, and execute the deployment without contacting the Developer (per §B.3 / §E.4).

The deploy is run by the Client from the Client's own wallet (per §B.3). The Developer may run throwaway pre-validation deploys from a disclosed dev wallet (see §6 below) but never the canonical deploy.

---

## 1. Scope and what this deploys

The canonical deploy produces two contract instances on Base Sepolia:

1. **`MockDRP`** — the frozen-interface DRP stub per v0.11.2 §9 and §C.3.7 ("DRP Stub Strategy"). Returns deterministic outcomes for testing; no dispute resolution logic, no economic evaluation.
2. **`Settlement`** — the Part 1 contract under test, wired to:
   - `USDC` = Circle's Base Sepolia USDC at `0x036CbD53842c5426634e7929541eC2318f3dCF7e`.
   - `DRP` = the `MockDRP` deployed alongside (`step 1`).
   - `admin` = the canonical admin address pinned 2026-05-26: `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`.
   - Default time windows = read from environment variables (see §3).

Base Mainnet is excluded from Part 1 scope per §C.3.5 / §C.3.7 and is not deployable from this script.

---

## 2. Prerequisites

| Item | Version / source |
|---|---|
| Foundry (`forge` + `cast`) | latest stable from <https://book.getfoundry.sh/getting-started/installation> |
| Solidity compiler | 0.8.24 (pinned in `foundry.toml`; Foundry downloads automatically on first build) |
| Repository | clean clone from the Client-owned GitHub repo (per §B.4) |
| Funded Base Sepolia EOA | the canonical admin wallet `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`, holding enough ETH to cover ~3.1M gas at current Base Sepolia gas prices (~0.000035 ETH at 0.011 gwei) |
| Basescan API key | optional, only required for source verification via `forge verify-contract` |

No other tooling is required. The deploy script reads everything it needs from environment variables; nothing about the Developer's local environment is referenced or required.

---

## 3. Environment configuration

```bash
cp .env.example .env
```

Open `.env` and confirm the values match the canonical configuration:

```
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
BASESCAN_API_KEY=<your_basescan_api_key_or_blank>

ADMIN_ADDRESS=0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e
USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e

DEFAULT_TW1_SECONDS=600
DEFAULT_TW2_SECONDS=1800
DEFAULT_TW3_SECONDS=3600
```

The `ADMIN_ADDRESS` is hard-required by `script/Deploy.s.sol` to equal `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`; the script reverts on any other value. To change this address, both Parties must agree in writing and the `CANONICAL_ADMIN` constant in `script/Deploy.s.sol` must be updated in a tracked commit.

Time-window values are illustrative defaults from the M1 RUNBOOK (10 min / 30 min / 1 hour). Adjust to whatever the verification flow requires — they affect only operational window length and are locked per-transaction at PoI commit (§C.3.3).

---

## 4. Build and local test (clean-clone reproducibility per §D.3.3)

From a fresh clone of the repository:

```bash
git submodule update --init --recursive
forge build
forge test --no-match-path "test/invariants/*"
forge test --match-path "test/invariants/*"
forge fmt --check
```

Expected:

- `forge build` — 0 errors, 0 warnings.
- `forge test --no-match-path "test/invariants/*"` — 70 / 70 unit + integration tests pass.
- `forge test --match-path "test/invariants/*"` — 8 / 8 invariant-suite tests pass (7 properties P1–P7 + the deterministic handler-wiring smoke test).
- `forge fmt --check` — no formatting diff.

If any of these fail on a clean clone, **stop and resolve before proceeding** — the deploy script is built against this test suite passing.

---

## 5. Canonical deploy

The deploy is executed by the Client from the Client's own wallet. The Client supplies the deployer key via Foundry's standard mechanisms — either an encrypted keystore (`--account <name>`, recommended) or `--private-key` (less safe; private key visible in shell history if used carelessly).

### 5.1 Simulation (no broadcast)

A simulation runs the deploy script end-to-end against the live RPC without sending any transactions. It confirms the script compiles, the env-var resolution succeeds, the constructor calls succeed, and the resulting state would be valid. Always run a simulation before a real broadcast.

```bash
source .env

forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --sender 0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e
```

Expected: `SIMULATION COMPLETE.` plus an estimated-gas line. No transactions are sent.

If the script reverts with `Deploy: ADMIN_ADDRESS must equal canonical admin pinned 2026-05-26`, the `ADMIN_ADDRESS` env var does not match the pinned canonical address — fix `.env` and retry.

### 5.2 Real broadcast (canonical deploy)

```bash
source .env

forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --account <your_keystore_name> \
  --broadcast \
  --verify \
  --etherscan-api-key "$BASESCAN_API_KEY"
```

Or with a private key (less safe — leaks into shell history; prefer keystore):

```bash
forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "$BASESCAN_API_KEY"
```

The `--verify` + `--etherscan-api-key` flags submit both `MockDRP` and `Settlement` source to Basescan for verification immediately after deployment. If the verification step fails (e.g., API key invalid), the deployment itself is unaffected — verification can be retried separately with `forge verify-contract`.

Expected output (post-broadcast):

```
MockDRP deployed at:  0x...
Settlement deployed at: 0x...
Admin (canonical):      0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e
USDC:                   0x036CbD53842c5426634e7929541eC2318f3dCF7e
TW1 / TW2 / TW3 (seconds): 600 1800 3600
```

Record the two deployed addresses. The remaining post-deploy verification checks (see `VERIFICATION.md`) operate against the `Settlement` address.

---

## 6. Developer dev/test deploys (informational — not for canonical use)

The Developer uses a dedicated dev wallet for throwaway pre-validation deploys before the canonical run. Per §B.3 and the 2026-05-26 acknowledgement, this wallet is disclosed to the Client in advance and is clearly not on record as the canonical deployer.

Dev wallet (disclosed 2026-05-26): `0x5b0C74AF01Ac1CFE5cD1EEB85F3c36f901048710`

The dev script is `script/DeployDev.s.sol`. It:
- Does **not** enforce the canonical-admin equality guard.
- Optionally deploys a fresh `MockERC20` inline if `USDC_ADDRESS` is not set (so the verification flow can mint freely without a faucet).
- Defaults the admin to `tx.origin` (the broadcaster EOA) if `ADMIN_ADDRESS` is unset.
- Uses M1-RUNBOOK time-window defaults (600 / 1800 / 3600) if env unset.

Dev instances deployed by `DeployDev.s.sol` are throwaway. They are **never** treated as canonical, never registered anywhere durable, and retire alongside the dev wallet after M3 acceptance.

---

## 7. Source verification (post-deploy, if `--verify` was not used)

If the deploy was run without `--verify` (e.g., the Basescan API key was unavailable at deploy time), source verification can be performed later:

```bash
forge verify-contract \
  --chain base_sepolia \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  <DEPLOYED_SETTLEMENT_ADDRESS> \
  src/Settlement.sol:Settlement \
  --constructor-args $(cast abi-encode \
    "constructor(address,address,address,(uint64,uint64,uint64))" \
    "$USDC_ADDRESS" \
    "<DEPLOYED_MOCKDRP_ADDRESS>" \
    "$ADMIN_ADDRESS" \
    "($DEFAULT_TW1_SECONDS,$DEFAULT_TW2_SECONDS,$DEFAULT_TW3_SECONDS)")

forge verify-contract \
  --chain base_sepolia \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  <DEPLOYED_MOCKDRP_ADDRESS> \
  test/mocks/MockDRP.sol:MockDRP
```

`MockDRP` has no constructor arguments. `Settlement`'s constructor signature is `(IERC20 usdc, IDRP drp, address admin, TimeWindows memory defaultTimeWindows)` where `TimeWindows` is a struct `(uint64 tw1, uint64 tw2, uint64 tw3)`.

---

## 8. After the deploy

- Run the verification checklist in `VERIFICATION.md` (at least six checks per §D.2.4) — exercises `commitPoI`, `submitPoR`, the escalation pokers, `invokeDRP`, and the terminal-finality paths against the deployed instance.
- Acceptance of M3 is gated on §D.3.3 clean-clone re-run (sections 4 + 5 + verification) by the Client, plus the Developer's written confirmation that no administrative or privileged access remains under the Developer's control (per §B.3 bullet 4 / §D.2.4 D13).

---

## 9. Operational notes

- **Branch protection:** `main` is protected per §B.4; all changes land via reviewed PR. Direct pushes to `main` are not used for code; tag-only direct pushes are used for milestone tags (`v0.1.0-m1`, `v0.2.0-m2`, `v0.3.0-m3`) per the M1 housekeeping precedent.
- **No upgradeability:** the contract is non-upgradeable post-deployment (§C.3.7 / §E.3). Any change to contract logic requires deploying a new contract version under a separate agreement (§E.3).
- **Multisig admin (`§E.2`):** out of scope for Part 1. The canonical admin on this deployment is the Client's EOA, not a Safe multisig. Section E applies only when production deployment is explicitly authorised under a separate phase beyond Part 1.
- **Test funds only:** Base Sepolia ETH and the testnet USDC referenced above have no real-world value. This is a validation artefact, not a production deployment (§C.1).
