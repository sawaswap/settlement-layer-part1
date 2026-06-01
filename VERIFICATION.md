# VERIFICATION.md — Settlement Layer M3 verification checklist

Six verification checks per §D.2.4 demonstrating reproducible deployment and basic post-deployment interaction on Base Sepolia. Run from a fresh clone of the repository, against the canonical Settlement instance deployed per `DEPLOYMENT.md`.

The checks are intended to be **runnable by the Client (or any competent third party) without contacting the Developer**. Every command is shell-paste-ready; expected outputs are explicit; pass / fail criteria are stated for each.

## Canonical instance (Base Sepolia 84532)

The canonical Settlement Layer (Part 1) deployment of record, broadcast on 2026-05-28 from the canonical admin wallet `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e` per §B.3:

| Contract | Address | Deploy tx |
|---|---|---|
| `Settlement` | [`0x9645827808E25b4e19B1B8A05B075606dfF86331`](https://sepolia.basescan.org/address/0x9645827808E25b4e19B1B8A05B075606dfF86331) | [`0x38999636…`](https://sepolia.basescan.org/tx/0x38999636d3f352b592b1e3c46e0070418e710ea45b270f56712e17c66e18e1b4) |
| `MockDRP` | [`0x9Fdb4DAE76C0D481b3fa46A0131D95e4000Ef769`](https://sepolia.basescan.org/address/0x9Fdb4DAE76C0D481b3fa46A0131D95e4000Ef769) | [`0x0d1d575d…`](https://sepolia.basescan.org/tx/0x0d1d575d3d9273a297f94d130aa13790cf31f745e7a9cbf5e52c7f6f42b4d3dc) |
| `USDC` (Circle Sepolia) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | — (already on chain) |
| Canonical admin | `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e` | — |
| Default TW1 / TW2 / TW3 | `600 / 1800 / 3600` seconds | — |

Recommended environment before starting:

```bash
source .env
export SETTLEMENT=0x9645827808E25b4e19B1B8A05B075606dfF86331
export MOCKDRP=0x9Fdb4DAE76C0D481b3fa46A0131D95e4000Ef769
export USDC=$USDC_ADDRESS                    # 0x036CbD53842c5426634e7929541eC2318f3dCF7e
export ADMIN=$ADMIN_ADDRESS                  # 0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e
export RPC=$BASE_SEPOLIA_RPC_URL             # https://sepolia.base.org
```

The verification commands below use `cast send` (signed, on-chain) and `cast call` (view, no gas). Replace `--account <name>` with `--private-key "$DEPLOYER_PRIVATE_KEY"` if not using a keystore.

---

## Check 1 — Reproducible build + test from a clean clone (§D.3.3)

**What it proves:** The repository at the merge commit compiles cleanly and the entire test suite passes on a fresh machine with no Developer assistance.

**Commands:**

```bash
# In a fresh, empty directory:
git clone <client_repo_url> sawaswap-m3-verify
cd sawaswap-m3-verify
git submodule update --init --recursive

forge --version            # records the Foundry version used
forge build                # 0 errors, 0 warnings
forge test --no-match-path "test/invariants/*"
forge test --match-path "test/invariants/*"
forge fmt --check
```

**Expected outputs:**

- `forge build` — `Compiler run successful!`, no warnings.
- `forge test --no-match-path "test/invariants/*"` — `70 passed; 0 failed; 0 skipped`.
- `forge test --match-path "test/invariants/*"` — `8 passed; 0 failed; 0 skipped` (7 properties P1–P7 + handler-wiring smoke test).
- `forge fmt --check` — empty output (no diff).

**Pass / fail:** All four steps green → PASS.

---

## Check 2 — Canonical deployment produces expected state

**What it proves:** Running `script/Deploy.s.sol` from the canonical admin wallet produces a `Settlement` contract whose constructor-set state matches the env configuration, with the canonical admin holding both `ADMIN_ROLE` and `DEFAULT_ADMIN_ROLE`.

**Commands:** (run after the canonical deploy per `DEPLOYMENT.md` §5.2)

```bash
# Verify USDC + DRP references on Settlement
cast call $SETTLEMENT "USDC()(address)" --rpc-url $RPC
cast call $SETTLEMENT "DRP()(address)" --rpc-url $RPC

# Verify default time windows match env
cast call $SETTLEMENT "getDefaultTimeWindows()((uint64,uint64,uint64))" --rpc-url $RPC

# Verify canonical admin holds both roles
ADMIN_ROLE_HASH=$(cast keccak "ADMIN_ROLE")
cast call $SETTLEMENT "hasRole(bytes32,address)(bool)" $ADMIN_ROLE_HASH $ADMIN --rpc-url $RPC
cast call $SETTLEMENT "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  $ADMIN --rpc-url $RPC

# Verify the dev wallet does NOT hold either role on the canonical instance
DEV_WALLET=0x5b0C74AF01Ac1CFE5cD1EEB85F3c36f901048710
cast call $SETTLEMENT "hasRole(bytes32,address)(bool)" $ADMIN_ROLE_HASH $DEV_WALLET --rpc-url $RPC
```

**Expected outputs:**

- `USDC()` returns `$USDC` (the Circle Base-Sepolia USDC address).
- `DRP()` returns `$MOCKDRP` (the deployed MockDRP address).
- `getDefaultTimeWindows()` returns `(DEFAULT_TW1_SECONDS, DEFAULT_TW2_SECONDS, DEFAULT_TW3_SECONDS)` from `.env`.
- `hasRole(ADMIN_ROLE, $ADMIN)` → `true`.
- `hasRole(DEFAULT_ADMIN_ROLE, $ADMIN)` → `true`.
- `hasRole(ADMIN_ROLE, $DEV_WALLET)` → `false` (Developer's dev wallet has no privileged access on the canonical instance, per §B.3 bullet 4).

**Pass / fail:** All six reads as expected → PASS.

---

## Check 3 — `commitPoI` happy path: escrow lock + STID round-trip

**What it proves:** A funded originator can commit a PoI, the contract pulls the escrow from their balance via `safeTransferFrom`, an STID is derived deterministically, and the full `Transaction` record can be read back via the getter.

**Commands:** (run from any funded Base Sepolia wallet with sufficient USDC balance and an approval set)

```bash
# Prerequisite: approve Settlement to spend USDC on behalf of the caller
APPROVE_AMOUNT=5000000  # 5 USDC (6 decimals)
cast send $USDC "approve(address,uint256)" $SETTLEMENT $APPROVE_AMOUNT \
  --rpc-url $RPC --account <name>

# Commit the PoI
MOMO_HASH=$(cast keccak "verification-leg-0001")
BENEFICIARY=0x000000000000000000000000000000000000bEEF
CLAIMANT=0x000000000000000000000000000000000000C0DE

cast send $SETTLEMENT \
  "commitPoI((address,address,uint8,uint256,bytes32))" \
  "($BENEFICIARY,$CLAIMANT,0,$APPROVE_AMOUNT,$MOMO_HASH)" \
  --rpc-url $RPC --account <name>
```

**Reading the STID from the receipt:**

The `PoICommitted` event carries the STID in `topics[1]`. After the `cast send` above completes, retrieve the most recent transaction by the caller and decode the event:

```bash
# Pull the latest tx receipt for your caller:
LATEST_HASH=<tx_hash_from_cast_send_output>
STID=$(cast receipt $LATEST_HASH --rpc-url $RPC --json | jq -r '.logs[0].topics[1]')
echo "STID: $STID"
```

**Round-trip the stored Transaction:**

```bash
cast call $SETTLEMENT \
  "getTransaction(bytes32)((bytes32,address,address,address,uint8,uint256,bytes32,uint64,uint64,uint64,uint64,uint8,bool,bool))" \
  $STID --rpc-url $RPC
```

**Expected outputs:**

- `cast send commitPoI` — succeeds, transaction mined.
- `getTransaction($STID)` returns a tuple with: `originator` = caller address, `beneficiary` = `0x...bEEF`, `eligibleClaimant` = `0x...C0DE`, `direction = 0` (CMM), `escrowAmount = 5000000`, `momoLegHash = $MOMO_HASH`, `tw1 / tw2 / tw3` matching the deployment defaults, `committedAt > 0`, `state = 0` (PoICommitted), `drpInvoked = false`, `terminalMoved = false`.
- USDC `balanceOf(Settlement)` increases by `APPROVE_AMOUNT` (escrow pulled).

**Pass / fail:** STID round-trip matches inputs and escrow moved → PASS.

---

## Check 4 — `submitPoR` → `Settled`: terminal finality on PoR

**What it proves:** Submitting a valid PoR within TW1 from the correct caller transitions the transaction to `Settled` and atomically releases the escrow to the beneficiary.

**Commands:** (run within TW1 of the `commitPoI` from Check 3, from the wallet whose address was supplied as `eligibleClaimant` in the commit — direction-symmetric: `eligibleClaimant` submits PoR on both CMM and MMC)

```bash
POR_DATA=0x0001706f725f7061796c6f6164  # version-prefixed (0x00, 0x01) + "por_payload"

cast send $SETTLEMENT "submitPoR(bytes32,bytes)" $STID $POR_DATA \
  --rpc-url $RPC --account <claimant_account>
```

**Verify terminal state:**

```bash
cast call $SETTLEMENT "getTransaction(bytes32)((bytes32,address,address,address,uint8,uint256,bytes32,uint64,uint64,uint64,uint64,uint8,bool,bool))" $STID --rpc-url $RPC

cast call $USDC "balanceOf(address)(uint256)" $BENEFICIARY --rpc-url $RPC
```

**Expected outputs:**

- `cast send submitPoR` — succeeds.
- `getTransaction($STID)` returns the same record with `state = 4` (`Settled`) and `terminalMoved = true`.
- USDC `balanceOf($BENEFICIARY)` has increased by `APPROVE_AMOUNT`.
- A second `cast send` of the same STID against any external entry reverts with the relevant state-guard or finality error.

**Pass / fail:** `state == Settled (4)`, `terminalMoved == true`, escrow at beneficiary → PASS.

---

## Check 5 — TW1 escalation → claim → DRP outcome

**What it proves:** When TW1 elapses without a PoR, anyone can `pokeTW1` to escalate; the eligible claimant can then `submitClaim` and `invokeDRP`, and the DRP outcome atomically transitions the transaction to a terminal state.

**Commands:** (start a fresh `commitPoI` for this check; do **not** call `submitPoR` this time; wait past TW1 — `DEFAULT_TW1_SECONDS = 600` so wall-clock ≥ 10 minutes, or set a shorter TW1 in your deploy for faster verification)

```bash
# Step 1: fresh commitPoI (as in Check 3); record $STID_C5
# Step 2: wait past TW1
# Step 3: pokeTW1 (permissionless — any caller works)
cast send $SETTLEMENT "pokeTW1(bytes32)" $STID_C5 --rpc-url $RPC --account <name>

# Step 4: confirm state moved to EscalationL1
cast call $SETTLEMENT "getTransaction(bytes32)((bytes32,address,address,address,uint8,uint256,bytes32,uint64,uint64,uint64,uint64,uint8,bool,bool))" $STID_C5 --rpc-url $RPC

# Step 5: configure MockDRP to return Settled for this STID
cast send $MOCKDRP "setOutcome(bytes32,uint8)" $STID_C5 0 --rpc-url $RPC --account <name>  # 0 = Settled

# Step 6: submitClaim from the eligible claimant ($CLAIMANT)
CLAIM_DATA=0x0001636c61696d5f7061796c6f6164  # versioned claim payload
cast send $SETTLEMENT "submitClaim(bytes32,bytes)" $STID_C5 $CLAIM_DATA \
  --rpc-url $RPC --account <claimant_account>

# Step 7: invokeDRP from the claimant (atomic outcome resolution)
cast send $SETTLEMENT "invokeDRP(bytes32)" $STID_C5 \
  --rpc-url $RPC --account <claimant_account>
```

**Expected outputs:**

- After Step 3: `getTransaction($STID_C5).state == 2` (`EscalationL1`).
- After Step 6: `getTransaction($STID_C5)` shows `getClaimHash($STID_C5)` non-zero, `state` still `2`.
- After Step 7: `state == 4` (`Settled`) and `terminalMoved == true`. Escrow moved to `$BENEFICIARY`. `drpInvoked == true`.

**Pass / fail:** Full escalation → DRP outcome → terminal finality observed → PASS.

---

## Check 6 — `expireTW3` default-reverse: liveness on a claimed transaction with no DRP outcome

**What it proves:** A claimed transaction whose DRP never produces an outcome can be default-reversed by anyone after the full `committedAt + tw1 + tw2 + tw3` window — the post-23-May-§C.3.8(a) remediation behaviour. Escrow returns to the originator.

**Commands:** (start fresh; same flow as Check 5 through `submitClaim` but skip `invokeDRP`; wait past `TW1 + TW2 + TW3`)

```bash
# Steps 1–6 as in Check 5 (commitPoI → wait → pokeTW1 → submitClaim) → record $STID_C6
# Step 7: wait past committedAt + TW1 + TW2 + TW3 wall-clock
# Step 8: anyone (permissionless poker) calls expireTW3
cast send $SETTLEMENT "expireTW3(bytes32)" $STID_C6 --rpc-url $RPC --account <any_account>

# Step 9: verify
cast call $SETTLEMENT "getTransaction(bytes32)((bytes32,address,address,address,uint8,uint256,bytes32,uint64,uint64,uint64,uint64,uint8,bool,bool))" $STID_C6 --rpc-url $RPC
cast call $USDC "balanceOf(address)(uint256)" $ORIGINATOR --rpc-url $RPC
```

**Expected outputs:**

- After Step 8: `state == 5` (`Reversed`) and `terminalMoved == true`. `drpInvoked == false` (DRP was never invoked on this flow).
- USDC `balanceOf($ORIGINATOR)` has increased by the escrow amount (escrow returned, not held by Settlement and not paid to beneficiary).
- A re-call of `expireTW3($STID_C6)` reverts with `AlreadyFinalized` or the relevant state guard.

**Pass / fail:** `state == Reversed (5)`, escrow back at originator, single-move invariant respected → PASS.

---

## Summary

Six checks ⇒ if all six PASS:

- §D.2.4 verification requirement satisfied.
- §D.3.3 clean-clone reproducibility demonstrated.
- §D.2.3 D4–D9 behavioural surface exercised end-to-end on Base Sepolia.
- Single-move escrow invariant (P1 / P3 / P5) observed live across both the PoR-Settled and the TW3-Reversed terminal paths.

For acceptance, attach the transcript (commands + outputs + tx hashes from Basescan) alongside the §B.3 written confirmation that no administrative or privileged access remains under the Developer's control.
