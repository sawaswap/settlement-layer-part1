# SawaSwap Settlement Layer — Part 1

Smart-contract implementation of the SawaSwap Settlement Layer **Part 1** state machine, per
[SawaSwap Core Protocol v0.11.2](#protocol-baseline). Built as a deterministic validation prototype
on Base Sepolia under the Software Development Agreement between BFR-Invest.com (Client) and
ALIAKSEI MIALESHKA (Developer, trading as FreeBlock).

This repository **is not** intended for production deployment or real-funds usage. It serves solely
as a validation artifact to confirm protocol behaviour prior to any production-oriented development
phase.

## Protocol baseline

The on-chain state machine implemented here is the Settlement Layer (Part 1) as frozen in
SawaSwap Core Protocol v0.11.2, comprising:

- The state set `{ PoI Committed / Escrow Locked, Execution Open / TW1, Escalation L1 / TW2,
  Escalation L2 / DRP / TW3, Settled, Reversed }`.
- The escrow single-move invariant (escrow moves exactly once at terminal finality).
- The direction-neutral eligible-claimant predicate (CMM → User C, MMC → Agent B).
- The Frozen DRP Boundary (single invocation, ≤ TW3, no escrow / state mutation, callable only by
  the Settlement Layer).

DRP internals, stake economics, and canonical case execution are **out of scope** and deferred to
Part 2.

## Milestone state

| Milestone | Status | Notes |
|----------:|:------:|-------|
| **M1 — Environment + Contract Skeleton (30%)** | this branch | state enum, transaction storage, `commitPoI`, getters, admin TW config, M2 stubs |
| **M2 — Settlement Layer State Machine (50%)** | pending | escrow lock, TW expiry transitions, PoR / Claim / DRP, terminal finality |
| **M3 — Testnet Deployment + Handover (20%)** | pending | Base Sepolia deploy, gas report, handover docs |

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) — install via `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- `git` 2.40+
- ~30 MB free disk for the OpenZeppelin submodule

## Quick start

```sh
git clone <repo-url> sawaswap-settlement
cd sawaswap-settlement
git submodule update --init --recursive
forge build
forge test -vvv
```

Expected output: `forge build` reports `Compiler run successful!` with zero warnings;
`forge test` reports `24 tests passed, 0 failed` (20 unit/integration + 4 invariants).

To run only the invariant suite:

```sh
forge test --match-path "test/invariants/*" -vvv
```

To run the formatter check:

```sh
forge fmt --check
```

## Repository layout

```
src/
├── Settlement.sol           # main contract (non-upgradeable, immutable post-deploy)
├── types/Types.sol          # State enum, Direction enum, PoIInput, Transaction, TimeWindows
├── libraries/STID.sol       # pure library for STID (transaction ID) derivation
└── interfaces/IDRP.sol      # frozen DRP boundary interface (M2 mock harness target)
test/
├── Settlement.t.sol         # 20 unit / integration tests
├── mocks/MockERC20.sol      # minimal ERC-20 mock for tests
└── invariants/
    ├── SettlementHandler.sol      # bounded driver
    └── SettlementInvariants.t.sol # 4 invariant properties
script/
└── Deploy.s.sol             # Base Sepolia deployment (M3)
```

## M1 scope at a glance

Implemented:

- `commitPoI(PoIInput)` — creates a transaction record, locks TW1 / TW2 / TW3 at PoI per §C.3.3.
- `getTransaction(stid)` / `transactionExists(stid)` / `getNonce(originator)` — read accessors.
- `getDefaultTimeWindows()` / `getRailPairTW1(railPairId)` — config accessors.
- `setDefaultTimeWindows(...)` / `setRailPairProfile(...)` — admin-restricted setters under the
  Parameter Configuration Carve-Out (§C.3.7).

Stubbed (revert `NotImplementedM1`) — to land in M2:

- `submitPoR`, `submitClaim`, `updateClaim`, `invokeDRP`, `settle`, `reverse`.

Production-deployment provisions in §E of the Agreement are gated to a separate phase beyond Part 1
and are not enforced for the testnet build.

## Network targets

- **Base Sepolia (testnet)** — primary deployment target for M3 validation.
- **Base Mainnet** — explicitly excluded from Part 1 unless separately agreed in writing (per §C.3.5).

## Contributing

All code is contributed via pull request to a feature branch (`feat/m<milestone>-<topic>` or
`chore/<topic>`). The `main` branch is protected; every PR is reviewed by the Client before merge.

The Developer does not push directly to `main` and does not fork or duplicate this repository
outside the local working environment used for performing services under the Agreement (per §B.4).

## License

UNLICENSED — see [LICENSE](./LICENSE). All rights reserved by BFR-Invest.com.
