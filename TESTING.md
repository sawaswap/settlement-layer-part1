# Testing Methodology — SawaSwap Settlement Layer Part 1

This document captures the **detailed testing methodology** that the Software Development Agreement
(§D.2.2 acceptance criteria, §C.3.7 Testing Approach) places in the technical scope and repository
documentation. The contract carries the minimum unit/integration test counts and the acceptance
criteria; this file carries the methodology, the invariant and property-based test definitions, and
the tooling decisions.

## Test taxonomy

The repository runs three layers of validation:

1. **Unit tests** — single-function calls under a controlled context. File: `test/Settlement.t.sol`.
2. **Integration tests** — sequences of calls that exercise interactions between functions (e.g.,
   `commitPoI` followed by an admin TW update followed by a stored-window lookup). Co-located with
   unit tests in `test/Settlement.t.sol`; not separately split for M1 because the surface is small.
3. **Invariant / property-based tests** — handler-driven random-call sequences that assert
   universal properties of the contract state. Files: `test/invariants/SettlementHandler.sol`,
   `test/invariants/SettlementInvariants.t.sol`.

## Tooling

- **Foundry** is the primary framework, per Agreement §C.3.7.
- **`forge test`** runs unit, integration, and invariant suites in a single invocation.
- **`forge fmt --check`** enforces formatting; gating CI step.
- **`forge coverage`** is used during M1 to check that all `Settlement.sol` external functions are
  hit at least once. Coverage targets formalise in M2 (state-machine path coverage).

Foundry version is the latest stable release at the time of M1 delivery. CI installs via
`foundry-rs/foundry-toolchain@v1`. OpenZeppelin Contracts is pinned at v5.0.2 (commit
`dbb6104ce834628e473d2173bbc9d47f81a9eec3`) via git submodule.

`foundry.toml` carries the relevant tuning:

- `solc_version = "0.8.24"` (no auto-detect drift).
- `optimizer = true`, `optimizer_runs = 200`.
- `[invariant] runs = 256, depth = 32, fail_on_revert = false`.
- `[fuzz] runs = 256` for property-based unit tests in M2.

## Determinism

The state machine, by §C.3.7, must remain "fully deterministic and testable without reliance on
off-chain or external resolution logic". The test suite encodes determinism by:

- Asserting state-enum ordering (`test_StateEnumeration_OrderingMatches`) so the ABI does not
  silently shift between releases.
- Storing locked-at-PoI time windows on the transaction (`test_TransactionStorage_TWLockedAtPoI`)
  so subsequent admin parameter changes do not alter in-flight transactions.
- Per-originator nonce in STID derivation (`test_Getter_NonceIncrementsPerOriginator`) so the
  transaction identifier is a deterministic function of the inputs and the originator's commitment
  index.

## M1 acceptance test mapping (§D.2.2)

The eight acceptance bullets in §D.2.2 each map to one or more named tests in
`test/Settlement.t.sol`:

| §D.2.2 bullet | Test(s) |
|---|---|
| deployment | `test_Deployment_SetsConstructorArgs`, `test_Deployment_RevertsOnZeroUSDC`, `test_Deployment_RevertsOnZeroAdmin`, `test_Deployment_RevertsOnZeroTimeWindow` |
| configuration | `test_Configuration_AdminCanSetTimeWindows`, `test_Configuration_NonAdminCannotSetTimeWindows`, `test_Configuration_AdminCanSetRailPairProfile`, `test_Configuration_RevertsOnZeroTW` |
| state enumeration | `test_StateEnumeration_OrderingMatches` |
| transaction creation (commitPoI) | `test_CommitPoI_CreatesTransaction` |
| state entry | `test_StateEntry_PoICommittedIsInitialState` |
| transaction storage | `test_TransactionStorage_PersistsAllFields`, `test_TransactionStorage_TWLockedAtPoI` |
| zero-amount revert conditions | `test_CommitPoI_RevertsOnZeroAmount`, `test_CommitPoI_RevertsOnZeroBeneficiary`, `test_CommitPoI_RevertsOnZeroClaimant` |
| getter functions | `test_Getter_RevertsOnUnknownSTID`, `test_Getter_TransactionExistsReturnsTrue`, `test_Getter_NonceIncrementsPerOriginator` |

Plus a bonus: `test_M2Stubs_RevertNotImplemented` confirms the six M2 protocol-action stubs revert
with `NotImplementedM1`, preventing testnet integrators from accidentally believing they succeeded.

## Property catalogue

The invariant suite asserts four properties. Each is exercised by Foundry over 256 runs of 32
random handler calls each (8192 successful `commitPoI` calls per property under `fail_on_revert =
false`).

### P1 — Terminal absorbing (M1: PoICommitted-only)

**Statement.** Once a transaction reaches a terminal state (`Settled` or `Reversed`), no subsequent
handler call mutates that transaction's state. In M1 there are no transitions out of
`PoICommitted`, so the strict M1 form of this property is: every committed transaction remains in
state `PoICommitted` and `terminalMoved` and `drpInvoked` remain false.

**Why.** Locks down the M1 contract surface against accidental future mutation paths and freezes
behaviour expected by §D.2.2's "state entry" acceptance bullet.

**Handler surface.** `commitPoI_bounded`.

**M2 expansion.** When state-machine transitions land, P1 generalises to: `Settled` and `Reversed`
are absorbing; once reached, the only legal subsequent calls are reads. Will require expanded
handler surface (PoR submission, claim submission, settle, reverse, DRP invocation).

### P2 — No transaction without commitPoI

**Statement.** For every STID the handler has recorded as committed, the contract reports
`transactionExists(stid) == true`, the stored `committedAt > 0`, and the stored `originator`,
`beneficiary`, `eligibleClaimant` are all non-zero.

**Why.** Defends against any path that could create a "ghost" transaction (e.g., default-zero
storage masquerading as a record). Anchors the existence sentinel.

**Handler surface.** `commitPoI_bounded`.

**M2 expansion.** No structural change; all M2 functions only operate on existing STIDs.

### P3 — Escrow amount immutability

**Statement.** For every committed STID, the stored `escrowAmount` equals the amount the handler
passed to `commitPoI` (recorded in handler storage). The amount is positive.

**Why.** In M2 the escrow is locked via `safeTransferFrom`; the amount stored at PoI must be the
authoritative reference for terminal payout. Any drift between input and storage is a defect.

**Handler surface.** `commitPoI_bounded`; M2 will add post-commit handler calls but the
*pre-terminal* invariant must remain.

**M2 expansion.** Strengthen to: stored `escrowAmount` is invariant across all pre-terminal calls.
After terminal finality (`Settled` / `Reversed`), the amount is the value transferred (matching
the recorded amount minus optional protocol fee — fee scope is in M2 only if the spec lands it).

### P4 — Time windows locked at PoI

**Statement.** For every committed STID, the stored `tw1`, `tw2`, `tw3` equal the default time
windows that were active at the moment of commit. Even if the admin subsequently calls
`setDefaultTimeWindows`, the transaction's stored windows do not change.

**Why.** Per §C.3.3, "all selected durations must be locked per transaction at PoI commitment".
This is the protocol's strong guarantee that an in-flight transaction does not have its timing
contract mutated by configuration drift.

**Handler surface.** Currently `commitPoI_bounded`. Could optionally extend to a handler that also
calls `setDefaultTimeWindows_bounded` (granted the admin role) so we observe the property under
post-commit defaults churn; deferred to M2 alongside the rail-pair profile resolution work.

**M2 expansion.** Same statement, exercised through a richer handler that mutates defaults
mid-sequence and across the directional rail-pair profile lookup.

## Coverage targets

**M1 (this milestone)** — every external function in `Settlement.sol` is hit at least once by
unit/integration tests. Verified via `forge coverage` ad hoc.

**M2 (forward)** — full state-machine path coverage:

- TW1 expiry → escalation L1 (PoR not received).
- PoR valid → Settled.
- Claim within TW2 → escalation L2 / DRP.
- DRP returns Settled / Reversed.
- All six terminal paths in §C.3.1 + the binary finality outcomes in §3.

Plus mandatory M2 invariant additions:

- Escrow conservation: `USDC.balanceOf(Settlement)` equals the sum of unsettled `escrowAmount`
  values across all in-flight transactions.
- Single-move escrow: `terminalMoved` flips exactly once and only at terminal finality.
- DRP single-invocation: `drpInvoked` flips at most once; the second `invokeDRP` reverts.

**M3** — at least six post-deployment verification checks on Base Sepolia, including:

- Independent third-party clean-clone reproducibility (`D.3.3` acceptance check).
- Round-trip a `commitPoI` call against the deployed contract.
- Storage and event verification via `cast`.
- Gas report for all Part 1 protocol actions.

## Running the suites

```sh
# All tests (unit + integration + invariants)
forge test -vvv

# Only invariants
forge test --match-path "test/invariants/*" -vvv

# Only a named test
forge test --match-test test_CommitPoI_CreatesTransaction -vvv

# With coverage
forge coverage --report summary

# Format check (CI-gating)
forge fmt --check
```

## CI integration

`.github/workflows/test.yml` runs on every push and pull request:

1. Checkout with submodules.
2. Install Foundry stable.
3. `forge --version`.
4. `forge fmt --check`.
5. `forge build --sizes`.
6. `forge test -vvv` (unit + integration + invariants).

A failure at any step blocks merge to `main`.
