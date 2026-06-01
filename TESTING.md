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
- **`forge coverage`** checks that every `Settlement.sol` external function and state-machine
  branch is exercised. Run as `forge coverage --report summary`.

Foundry version is the latest stable release at the time of delivery. CI installs via
`foundry-rs/foundry-toolchain@v1`. OpenZeppelin Contracts is pinned at v5.0.2 (commit
`dbb6104ce834628e473d2173bbc9d47f81a9eec3`) via git submodule.

`foundry.toml` carries the relevant tuning:

- `solc_version = "0.8.24"` (no auto-detect drift).
- `optimizer = true`, `optimizer_runs = 200`.
- `[invariant] runs = 256, depth = 64, fail_on_revert = false` — `depth` was raised from 32 to 64
  in M2 so the fuzzer can reach the deeper states of the widened transition surface
  (commit → TW1 escalation → claim → DRP boundary → terminal) within a single run.
- `[fuzz] runs = 256`.

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

Plus a bonus: `test_RemainingM2Stubs_RevertNotImplemented` confirms the remaining unimplemented
external entries revert with `NotImplementedM1`. As M2 PRs land, implemented functions drop out of
that test; by M2 close only `settle` / `reverse` remain (retained as reverting ABI placeholders
per the 15 May ratified decision to drop the external recovery-hatch track).

## M2 acceptance test mapping (§D.2.3)

M2 implements §D.2.3 deliverables D4–D9. The unit/integration tests are organised into six
categories in `test/Settlement.t.sol`, each a numbered section; the §D.2.3 floor of 24
unit/integration tests is exceeded (70 at M2 close).

| §D.2.3 area | Test section | Coverage |
|---|---|---|
| D4 — escrow lock + terminal escrow movement | 6.5 Escrow lock at PoI; 6.7 Finality | escrow pulled at `commitPoI`; escrow moves exactly once at terminal finality; terminal outcome is only `Settled` / `Reversed` |
| D5 — TW1 / TW2 / TW3 timing | 6.8 TW1 expiry escalation; 6.9 TW2 default-reverse; 6.10 TW3 default-reverse | each window's expiry path: TW1 → `EscalationL1`; TW2 → default-reverse; TW3 → default-reverse |
| D6 — PoR submission + verification gate | 6.6 PoR submission and Settled finality | valid PoR within TW1 → `Settled`; caller / state / window / payload guards |
| D7 — claim submission + eligible-claimant predicate | 6.9 Claim submission and TW2 default-reverse | `submitClaim` / `updateClaim` against the eligible-claimant predicate; TW2-bound mutability |
| D8 — DRP frozen interface stub + configurable mock harness | 6.10 DRP boundary and TW3 default-reverse | `invokeDRP` binary-outcome handling; `MockDRP` configurable harness; reentrancy boundary via `MaliciousMockDRP` |
| D9 — unit tests for execution + escalation paths | sections 6.5–6.10 + invariant suite | 70 unit/integration tests + 7 invariant properties; all happy paths and the full revert-path surface of every external entry |

## Property catalogue

The invariant suite (`test/invariants/SettlementInvariants.t.sol`) asserts seven properties (P1–P7)
over the full M2 transition surface. The handler (`test/invariants/SettlementHandler.sol`) registers
every M2 entry point (`commitPoI`, `submitPoR`, `pokeTW1`, `submitClaim`, `updateClaim`,
`expireTW2`, `invokeDRP`, `expireTW3`) plus a time-advancement action, so the fuzzer explores the
whole state machine. Foundry runs 256 runs of 64 random handler calls each under
`fail_on_revert = false`.

Because Foundry reverts handler storage to the post-`setUp` snapshot between invariant runs, the
per-function attempt/success counters cannot be aggregated across a campaign. The guard against the
"handler always reverts" antipattern is therefore the deterministic
`test_HandlerWiring_AllBoundedTransitionsCanSucceed` smoke test, which drives every handler entry
point through a hand-picked success path and asserts its success counter increments. Campaign-wide
call distribution is separately visible in Foundry's per-selector summary table.

### P1 — Terminal absorbing

**Statement.** The `terminalMoved` flag and a terminal state (`Settled` / `Reversed`) are set
together, by the finalisation helpers and nothing else; no transition leaves a terminal state. The
invariant asserts the biconditional `terminalMoved <=> (state is Settled or Reversed)`.

**Why.** Catches both a terminal transaction re-leaving its state and `terminalMoved` being set
without the matching terminal transition. Anchors §C.3.4 determinism and the §3 binary-finality
guarantee.

**Handler surface.** Full M2 surface — terminal states are reached via `submitPoR`, `expireTW2`,
`invokeDRP`, `expireTW3`.

### P2 — No transaction without commitPoI

**Statement.** For every recorded STID, `transactionExists(stid) == true`, `committedAt > 0`, and
`originator` / `beneficiary` / `eligibleClaimant` are all non-zero.

**Why.** Defends against any path that could create a "ghost" transaction. Anchors the existence
sentinel.

**Handler surface.** `commitPoI_bounded`; all M2 functions only operate on existing STIDs.

### P3 — Escrow conservation

**Statement.** The Settlement contract's USDC balance equals the sum of `escrowAmount` over exactly
the transactions that have NOT terminal-moved. Escrow is held from `commitPoI` until the terminal
transition releases it; once `terminalMoved` flips true the transaction drops out of the active sum.

**Why.** The strong escrow-accounting guarantee: no escrow is lost, double-counted, or stranded.
Anchors §3 escrow [1] and §C.2.

**Handler surface.** Full M2 surface — the balance changes on `commitPoI` (in) and on every
terminal transition (out).

### P4 — Time windows locked at PoI

**Statement.** For every committed STID, the stored `tw1` / `tw2` / `tw3` equal the defaults active
at the moment of commit, regardless of subsequent admin `setDefaultTimeWindows` calls.

**Why.** Per §C.3.3, "all selected durations must be locked per transaction at PoI commitment" —
the protocol's guarantee that an in-flight transaction's timing contract is not mutated by
configuration drift.

**Handler surface.** `commitPoI_bounded`.

### P5 — Single-move (escrow amount immutability)

**Statement.** The escrow amount recorded at `commitPoI` never changes for the life of the
transaction.

**Why.** Combined with P1 (`terminalMoved` tracks the terminal transition) and P3 (terminal escrow
is excluded from the contract balance), this gives the single-move invariant: escrow leaves the
contract exactly once, at the terminal transition, in precisely the committed amount. Anchors
§C.3.4 and the §3 single-move guarantee.

**Handler surface.** Full M2 surface — asserted across all pre- and post-terminal states.

### P6 — DRP single-invocation consistency

**Statement.** `drpInvoked == true` implies the state is `EscalationL2_DRP`, `Settled`, or
`Reversed` — never `PoICommitted` or `EscalationL1`. `drpInvoked` is set only as part of the
`invokeDRP` transition.

**Why.** The DRP boundary is crossed at most once per STID (addendum §2 / v0.11.2 §9). A second
`invokeDRP` is blocked by the state guard and the `DRPAlreadyInvoked` guard; this invariant
confirms `drpInvoked` is never set spuriously outside the DRP transition.

**Handler surface.** `invokeDRP_bounded` sets `drpInvoked`; the invariant holds across the full
surface.

### P7 — Eligible-claimant immutability

**Statement.** The `eligibleClaimant` recorded at `commitPoI` never changes.

**Why.** The claimant predicate gates `submitPoR` / `submitClaim` / `updateClaim` / `invokeDRP`; a
mutable claimant would silently widen the authorised-caller set. Anchors §C.2 and §5–§7.

**Handler surface.** Full M2 surface.

## Coverage targets

**M1** — every external function in `Settlement.sol` hit at least once by unit/integration tests.

**M2 (this milestone)** — full state-machine path coverage, achieved:

- TW1 expiry → `EscalationL1` (PoR not received) — section 6.8.
- Valid PoR within TW1 → `Settled` — section 6.6.
- Claim within TW2 → `EscalationL1` claim lifecycle — section 6.9.
- TW2 expiry without claim → default-reverse → `Reversed` — section 6.9.
- DRP invocation → `EscalationL2_DRP` → `Settled` / `Reversed` on binary outcome — section 6.10.
- TW3 expiry without DRP outcome → default-reverse → `Reversed` — section 6.10.
- Terminal outcomes restricted to `Settled` / `Reversed`; escrow moves exactly once — section 6.7.

M2 invariant additions, all landed (P3 / P5 / P6 in the catalogue above):

- P3 escrow conservation: `USDC.balanceOf(Settlement)` equals the sum of non-terminal
  `escrowAmount` values.
- P5 single-move escrow: escrow leaves the contract exactly once, at terminal finality, in the
  committed amount.
- P6 DRP single-invocation: `drpInvoked` is set only within the `invokeDRP` transition; a second
  `invokeDRP` reverts.

## M3 acceptance test mapping (§D.2.4)

M3 is deployment + handover (D10–D13). The verification surface is six checks against the
canonical Base Sepolia deployment plus the existing unit / integration / invariant suite. The
verification checklist itself lives in [`VERIFICATION.md`](./VERIFICATION.md), the gas report in
[`gas-report.md`](./gas-report.md), and the canonical deploy procedure in
[`DEPLOYMENT.md`](./DEPLOYMENT.md).

| §D.2.4 area | Artefact | Coverage |
|---|---|---|
| D10 — Base Sepolia deployment | `script/Deploy.s.sol` + `DEPLOYMENT.md` | canonical script with hard-required canonical admin (`0x434F2A01...`) via constructor; deploys `MockDRP` + `Settlement`; third-party-reproducible per §B.3 / §E.4 |
| D11 — Gas report | `gas-report.md` | deployment cost (live measurement + Base mainnet estimate at illustrative gas / ETH-USD); per-function gas for `commitPoI` / `submitPoR` / `pokeTW1` / `submitClaim` / `updateClaim` / `invokeDRP` / `expireTW2` / `expireTW3`; end-to-end lifecycle cost for happy / DRP / default-reverse paths |
| D12 — Documentation | `README.md`, `DEPLOYMENT.md`, `TESTING.md` | repo overview + quick start; step-by-step canonical deploy; testing methodology + property catalogue + per-milestone mappings |
| D13 — Handover | `VERIFICATION.md` + `HANDOVER.md` (§B.3 bullet 4 written no-residual-access attestation) | six verification checks: clean-clone build + test, deployment-state read, `commitPoI` round-trip, PoR → Settled, TW1 escalation → DRP outcome, `expireTW3` default-reverse; plus written attestation on-chain-verifiable via VERIFICATION.md Check 2 |

The six VERIFICATION.md checks exercise the §D.2.3 D4–D9 surface end-to-end against the deployed
canonical instance, complementing the in-repo unit / integration / invariant coverage with live
on-chain reproduction.

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
