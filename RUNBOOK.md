# Settlement Layer — Base Sepolia Demo RUNBOOK

This document supports a hands-on walkthrough of the **M1 Settlement contract surface** on a live Base Sepolia testnet deployment. It is informal documentation accompanying an out-of-scope demo instance; it is **not** part of the §D.2.2 M1 acceptance scope, and it is not the M3 production-bound deployment.

---

## 1. Scope and what this is not

**What this is.** A throwaway deployment of `Settlement.sol` at the M1 PR head (branch `feat/m1-bootstrap`) to Base Sepolia, suitable for exercising the M1 surface end-to-end: `commitPoI`, transaction storage, the getters, and the M2 stubs (so you can see them revert by design rather than mistake them for broken functionality).

**What this is not.**

- Not the M3 production deployment. M3 will deploy a fresh instance with the Client multisig as `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` holder, final TW defaults, and a deliberate broadcast plan per §B.4. **Do not treat this contract address as the canonical SawaSwap deployment.**
- Not a state-transition demo. The M2 functions (`submitPoR`, `submitClaim`, `updateClaim`, `invokeDRP`, `settle`, `reverse`) revert with `NotImplementedM1()` — this is the M1 scope boundary, not a failure.
- Not USDC-aware in a meaningful way. M1 records `escrowAmount` in `commitPoI` but does not move USDC; escrow lock arrives in M2. You do **not** need testnet USDC to walk this through.

---

## 2. Deployment artefacts

| Item | Value |
|---|---|
| Network | Base Sepolia |
| Chain ID | `84532` |
| Public RPC | `https://sepolia.base.org` |
| Explorer | `https://sepolia.basescan.org` |
| `Settlement` address | [`0xE0B9f9398641E5398Ba5377417eEed3B01c7313C`](https://sepolia.basescan.org/address/0xe0b9f9398641e5398ba5377417eeed3b01c7313c#code) — source verified |
| Deploy TX | `0x762ca21b3e0bf23d1c896b0fc8b8b0701cf3d9aa4cc2994aea38076f81c1915d` |
| Deployer (also admin) | `0x190D8A377cA64b95b199E8f2b3Ca7cA5D1B41BA1` |
| `USDC` reference | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (Circle Sepolia USDC) |
| Default TW1 / TW2 / TW3 | `600` / `1800` / `3600` seconds (10 min / 30 min / 1 hour) |
| Source tag | head of `feat/m1-bootstrap` at commit `52fad89` |

The deployer wallet holds both `DEFAULT_ADMIN_ROLE` and (transitively) `ADMIN_ROLE` for the duration of this demo. On M3 these roles move to a Safe multisig.

---

## 3. Prerequisites

- `foundry` toolkit (`cast` is sufficient; full Foundry is needed only if you want to re-run scripts or unit tests).
- A funded Base Sepolia EOA. You do not need to hold this contract's admin key for any demo step on this page; the read-only and `commitPoI` steps work from any funded wallet.
- Environment variables for convenience:

```bash
export RPC_URL=https://sepolia.base.org
export SETTLEMENT=0xE0B9f9398641E5398Ba5377417eEed3B01c7313C
export PRIVATE_KEY=<your funded Base Sepolia private key>
```

---

## 4. Happy path — `commitPoI` end-to-end

### 4.1 Construct a PoI

`PoIInput` is the tuple `(address beneficiary, address eligibleClaimant, Direction direction, uint256 escrowAmount, bytes32 momoLegHash)`. `Direction` is `CMM = 0` (Crypto → Mobile Money, User A → User C via Agent B) or `MMC = 1` (Mobile Money → Crypto). The `originator` is taken from `msg.sender`, not from the input.

A worked example (1 USDC of intended escrow, CMM direction, arbitrary off-chain leg digest):

```bash
MOMO_HASH=$(cast keccak "sawaswap-demo-leg-0001")
# 0x075ab0177d9eb4e476d62a270dfeff6dff12bbfd173d4a71edd1092e4d6108aa

cast send "$SETTLEMENT" \
  "commitPoI((address,address,uint8,uint256,bytes32))" \
  "(0x000000000000000000000000000000000000bEEF,\
0x000000000000000000000000000000000000C0DE,\
0,\
5000000,\
$MOMO_HASH)" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

`5000000` is 5 USDC at 6dp. The recipient addresses are illustrative.

### 4.2 Read the STID from the emitted event

`PoICommitted` carries the STID in `topics[1]`. From a `cast send` receipt, look at the first log entry on the contract:

```
topics[0] = keccak256("PoICommitted(bytes32,address,address,uint8,uint256,uint64,uint64,uint64)")
topics[1] = <STID>
topics[2] = <originator, padded>
topics[3] = <beneficiary, padded>
```

The reference run from the deploy produced STID `0x8aba44be92234f38e1e9390f31d4636bb854572b474b8afa537e2b8d35a4270b` in TX `0x3914cc91ffee74d42aab22fa53f7bfc813ea7e1464599d47e4c02cdd3aa4e797` — visible on the explorer above. Use it directly if you do not want to issue your own commit.

### 4.3 Read state back

```bash
STID=0x8aba44be92234f38e1e9390f31d4636bb854572b474b8afa537e2b8d35a4270b

cast call "$SETTLEMENT" \
  "getTransaction(bytes32)((bytes32,address,address,address,uint8,uint256,bytes32,uint64,uint64,uint64,uint64,uint8,bool,bool))" \
  $STID --rpc-url "$RPC_URL"
```

Returned tuple layout matches `Transaction` in `src/types/Types.sol`:

```
(stid, originator, beneficiary, eligibleClaimant, direction,
 escrowAmount, momoLegHash, tw1, tw2, tw3, committedAt,
 state, drpInvoked, terminalMoved)
```

For the reference STID above:

- `state = 0` → `State.PoICommitted` (entry state).
- `tw1/tw2/tw3 = 600 / 1800 / 3600` — locked at PoI, do not move with subsequent admin changes to the defaults (per §C.3.3).
- `drpInvoked = false`, `terminalMoved = false` — no transitions in M1.

---

## 5. Configuration / admin surface (read-only on this demo)

These are gated by `ADMIN_ROLE` and bound to the deployer wallet on this instance. You can **read** the current values without privileges:

```bash
cast call "$SETTLEMENT" "getDefaultTimeWindows()((uint64,uint64,uint64))" --rpc-url "$RPC_URL"
cast call "$SETTLEMENT" "getRailPairTW1(bytes32)(uint64)" 0x0... --rpc-url "$RPC_URL"
```

The admin-only setters exist for completeness:

```
setDefaultTimeWindows(uint64 tw1, uint64 tw2, uint64 tw3)
setRailPairProfile(bytes32 railPairId, uint64 tw1)
```

Calling either from a non-admin wallet reverts with `AccessControlUnauthorizedAccount(address,bytes32)` (the OpenZeppelin v5 access-control error, not one of this contract's custom errors).

`setDefaultTimeWindows` enforces the documented window ceilings — TW2 ≤ 36h (`MAX_TW2`), TW3 ≤ 72h (`MAX_TW3`); an over-range value reverts `TimeWindowTooLong()`, a zero value reverts `InvalidTimeWindow()`.

> **Rail-pair TW1 override — RESERVED, not consumed in Part 1.** `setRailPairProfile` / `getRailPairTW1` store and read a per-rail-pair TW1 value, but **nothing in Part 1 reads it**: `commitPoI` records the default `getDefaultTimeWindows().tw1` on every transaction and never consults a rail-pair override, and `PoIInput` carries no `railPairId` to key one off. The setter/getter exist so the admin surface stays stable ahead of the later Part that wires rail-pair selection into the commit input. Do not expect a rail-pair override to change a committed transaction's TW1 on this deployment. (KRAIT-002 audit correction.)

---

## 6. M2 stubs — expected reverts

Six functions exist in the ABI but revert with `NotImplementedM1()` until M2 lands. Calling any of them is **not a failure**, it is the M1 scope boundary made explicit so testnet integrators do not get a silent success on an unimplemented path.

```
submitPoR(bytes32 stid, bytes calldata pkdReceipt)
submitClaim(bytes32 stid, bytes calldata evidence)
updateClaim(bytes32 stid, bytes calldata evidence)
invokeDRP(bytes32 stid)
settle(bytes32 stid)
reverse(bytes32 stid)
```

Quick check that the boundary is in place:

```bash
cast call "$SETTLEMENT" "submitPoR(bytes32,bytes)" $STID 0x --rpc-url "$RPC_URL"
# Error: execution reverted, data: "0x21ad2be9"
```

`0x21ad2be9` is `NotImplementedM1()`.

---

## 7. Custom error selectors

For decoding revert reasons from `cast` output:

| Selector | Error |
|---|---|
| `0x1f2a2005` | `ZeroAmount()` |
| `0xbcfe5400` | `DuplicateSTID()` |
| `0x31fb878f` | `TransactionNotFound()` |
| `0x21ad2be9` | `NotImplementedM1()` |
| `0xb11cd481` | `InvalidTimeWindow()` |
| `0xe6c4247b` | `InvalidAddress()` |

OpenZeppelin v5 access-control failures surface as `AccessControlUnauthorizedAccount(address,bytes32)` rather than a custom error of this contract.

---

## 8. What is deliberately absent from this demo

- **State transitions beyond `PoICommitted`.** Movement to `ExecutionOpen`, `EscalationL1`, `EscalationL2_DRP`, `Settled`, `Reversed` is M2 work and depends on the corresponding stubbed functions.
- **Real USDC movement.** No `transferFrom` on `commitPoI` in M1; escrow lock arrives in M2.
- **DRP mock harness.** Arrives in M2 alongside `invokeDRP` body.
- **Multisig admin.** This instance uses the deployer EOA as admin to keep the demo self-contained. M3 will use a Client-controlled Safe.
- **Mainnet deployment** and **third-party audit**. Out of Part 1 scope per §C.3.5 / §C.3.7 / Section E.

If anything here renders ambiguous against the contract source, the source on `feat/m1-bootstrap` is authoritative.
