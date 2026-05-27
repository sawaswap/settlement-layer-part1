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
| **M1 — Environment + Contract Skeleton (30%)** | accepted 2026-05-11 | state enum, transaction storage, `commitPoI`, getters, admin TW config, M2 stubs; tag `v0.1.0-m1` |
| **M2 — Settlement Layer State Machine (50%)** | accepted 2026-05-24 | escrow lock, TW expiry transitions, PoR / claim / DRP, terminal finality, 70 unit + 8 invariant tests; tag `v0.2.0-m2` |
| **M3 — Testnet Deployment + Handover (20%)** | in flight | Base Sepolia deploy script + dev variant, deployment guide, gas report, verification checklist, handover docs |

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
forge test --no-match-path "test/invariants/*"   # 70 unit / integration tests
forge test --match-path "test/invariants/*"      # 8 invariant-suite tests (7 properties + smoke)
```

Expected: `forge build` reports `Compiler run successful!` with zero warnings; both `forge test`
invocations report all tests passing.

To run the formatter check:

```sh
forge fmt --check
```

For a gas report:

```sh
forge test --gas-report --no-match-path "test/invariants/*"
```

See [`gas-report.md`](./gas-report.md) for per-function gas measurements with USD cost estimates.

## Repository layout

```
src/
├── Settlement.sol           # main contract (non-upgradeable, immutable post-deploy)
├── types/Types.sol          # State enum, Direction enum, PoIInput, Transaction, TimeWindows
├── libraries/STID.sol       # pure library for STID (transaction ID) derivation
└── interfaces/IDRP.sol      # frozen DRP boundary interface
test/
├── Settlement.t.sol         # 70 unit / integration tests across sections 6.1–6.10
├── mocks/
│   ├── MockERC20.sol        # minimal ERC-20 mock used as escrow asset in tests
│   ├── MockDRP.sol          # configurable DRP harness (frozen-interface stub per §C.3.7)
│   └── MaliciousMockDRP.sol # reentrancy-attempt variant exercising the nonReentrant boundary
└── invariants/
    ├── SettlementHandler.sol      # bounded handler driving the full M2 transition surface
    └── SettlementInvariants.t.sol # 7 invariant properties P1–P7 + the deterministic wiring smoke test
script/
├── Deploy.s.sol             # canonical M3 deploy — admin pinned to the canonical wallet via hard require
└── DeployDev.s.sol          # Developer-side dev variant for throwaway pre-validation deploys
```

Top-level documentation:

- [`DEPLOYMENT.md`](./DEPLOYMENT.md) — third-party-reproducible canonical deploy guide (§D.2.4 D10–D12).
- [`VERIFICATION.md`](./VERIFICATION.md) — six post-deployment verification checks (§D.2.4 D13).
- [`gas-report.md`](./gas-report.md) — per-function gas + deployment cost with USD estimates (§D.2.4 D11 / §C.3.6).
- [`HANDOVER.md`](./HANDOVER.md) — §B.3 bullet 4 written no-residual-access attestation at M3 delivery (§D.2.4 D13).
- [`TESTING.md`](./TESTING.md) — testing methodology, property catalogue, per-milestone test mappings.

## Deploying to Base Sepolia

Read [`DEPLOYMENT.md`](./DEPLOYMENT.md) for the step-by-step canonical deploy guide. The guide is
written third-party-reproducible per §B.3 / §E.4 — a competent third party who has not interacted
with the Developer can read the repository, install the environment, and execute the deploy.

The canonical deploy is run by the Client from the Client's own wallet (per §B.3). Per the
Client's 2026-05-26 pinning, the canonical admin address is
`0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`; `Deploy.s.sol` enforces this via a hard `require`
and will revert on any other admin. Base Mainnet deployment is excluded from Part 1 per §C.3.5.

## Verification

After the canonical deploy, the [`VERIFICATION.md`](./VERIFICATION.md) checklist walks six checks
per §D.2.4: reproducible build, deployment-state validation, `commitPoI` happy path, PoR-Settled,
TW1 escalation + DRP outcome, and the TW3 default-reverse path. Each check is shell-paste-ready
with explicit expected outputs and pass / fail criteria.

## Testing methodology

[`TESTING.md`](./TESTING.md) is the authoritative testing-methodology document — taxonomy, tooling,
the per-milestone test mappings (§D.2.2 M1, §D.2.3 M2, §D.2.4 M3), the P1–P7 property catalogue
with v0.11.2 clause anchors, coverage targets, and CI integration notes.

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
