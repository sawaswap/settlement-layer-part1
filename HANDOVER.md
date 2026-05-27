# HANDOVER.md — Settlement Layer Part 1 / M3 written attestation

Written confirmation per §B.3 bullet 4 of the Software Development Agreement, satisfying §D.2.4 D13 ("written handover and access confirmation"). Recorded as a permanent repository artefact at M3 delivery.

## Canonical deployment of record

- **Chain:** Base Sepolia (testnet), chainId `84532`.
- **Settlement:** [`0x9645827808E25b4e19B1B8A05B075606dfF86331`](https://sepolia.basescan.org/address/0x9645827808E25b4e19B1B8A05B075606dfF86331).
- **MockDRP:** [`0x9Fdb4DAE76C0D481b3fa46A0131D95e4000Ef769`](https://sepolia.basescan.org/address/0x9Fdb4DAE76C0D481b3fa46A0131D95e4000Ef769).
- **USDC (escrow asset):** `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (Circle's Base Sepolia testnet USDC; already on chain, not deployed by the script).
- **Canonical admin / deployer wallet:** `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e` (Client-controlled, pinned by the Client on 2026-05-26).
- **Deploy txs:** [`0x0d1d575d…`](https://sepolia.basescan.org/tx/0x0d1d575d3d9273a297f94d130aa13790cf31f745e7a9cbf5e52c7f6f42b4d3dc) (MockDRP) and [`0x38999636…`](https://sepolia.basescan.org/tx/0x38999636d3f352b592b1e3c46e0070418e710ea45b270f56712e17c66e18e1b4) (Settlement); both at block `42110394`.

## Attestation — no residual privileged access (§B.3 bullet 4)

The Developer attests, as of M3 delivery:

1. **On-chain roles.** The Developer holds no roles on the canonical `Settlement` instance:
   - `hasRole(ADMIN_ROLE, 0x5b0C74AF01Ac1CFE5cD1EEB85F3c36f901048710)` = `false` — the M3 dev wallet (disclosed 2026-05-26 for our throwaway pre-validation deploys).
   - `hasRole(DEFAULT_ADMIN_ROLE, 0x5b0C74AF01Ac1CFE5cD1EEB85F3c36f901048710)` = `false` — same.
   - No other address under Developer control has been granted either role on this instance. The constructor (`src/Settlement.sol:185-198`) grants both `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` exclusively to the `admin` parameter, which the canonical deploy script (`script/Deploy.s.sol`) hard-requires to equal the Client's canonical admin wallet `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`. These assertions can be re-verified at any time via [`VERIFICATION.md`](./VERIFICATION.md) Check 2.

2. **Contract logic / upgrade rights.** The contract is non-upgradeable and immutable post-deployment (§C.3.7 / §E.3): no proxy pattern, no upgrade mechanism, no admin-controlled logic modification. The Developer has no path to modify deployed bytecode.

3. **Admin-gated surface.** `ADMIN_ROLE` exposes exactly two functions, both restricted to time-window configuration per the §C.3.7 Parameter Configuration Carve-Out: `setDefaultTimeWindows(uint64, uint64, uint64)` and `setRailPairProfile(bytes32, uint64)`. Both affect future commitments only — by Invariant P4 (Time windows locked at PoI / §C.3.3), in-flight transactions retain their commit-time windows regardless of subsequent admin updates. No pause, drain, sweep, withdraw, recover, emergency, rescue, or other state / escrow / logic mutation paths exist. Full enumeration in correspondence (2026-05-27 admin-surface answer).

4. **Off-chain infrastructure.** All infrastructure used for development sits in the Developer's local working environment per §B.4. No RPC endpoints, backend services, API keys, or domain names tied to the canonical deployment are registered or controlled by the Developer. Submission of source to Basescan for verification (if used) is a metadata operation that confers no access. The Developer's dev wallet's private key (the `0x5b0C74AF…` address above) is in the Developer's local `.env` and is retired at M3 acceptance; it has never been granted any role on the canonical instance and cannot acquire one without the canonical admin's explicit `grantRole` call.

5. **Source code.** All source delivered under this Agreement is in the Client-owned repository per §B.4. The Developer has no fork, copy, or duplicate outside the local working environment used for performing services under the Agreement.

## Re-verifying this attestation

Any party may re-verify (1) above directly against the on-chain canonical instance:

```bash
SETTLE=0x9645827808E25b4e19B1B8A05B075606dfF86331
DEV=0x5b0C74AF01Ac1CFE5cD1EEB85F3c36f901048710
ADMIN_ROLE_HASH=$(cast keccak "ADMIN_ROLE")
DEFAULT_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

# Both must return false:
cast call $SETTLE "hasRole(bytes32,address)(bool)" $ADMIN_ROLE_HASH $DEV --rpc-url https://sepolia.base.org
cast call $SETTLE "hasRole(bytes32,address)(bool)" $DEFAULT_ROLE $DEV --rpc-url https://sepolia.base.org
```

Both calls return `false` as of M3 delivery, confirming no residual privileged access of the Developer on the canonical instance. The contract source on the merge commit is the authoritative record of the absence of additional admin paths beyond those enumerated above.

## Mapping against the warranties

- **§B.3 bullet 4** — written confirmation that no administrative or privileged access remains under Developer control: provided above, source-anchored + on-chain verifiable.
- **§D.2.4 D13** — written handover and access confirmation: this document.
- **§E.3** — non-upgradeable / no proxy / no admin-controlled logic modification: confirmed by source enumeration.
- **§F.1 Developer warranties** — no backdoor, no hidden admin function, no undisclosed access mechanism: confirmed by the full admin-surface enumeration (this document §3 above + the 27 May correspondence).

This document, together with `VERIFICATION.md`, `gas-report.md`, `DEPLOYMENT.md`, `TESTING.md`, and the M2-era property catalogue, constitutes the M3 handover artefact set per §D.2.4.
