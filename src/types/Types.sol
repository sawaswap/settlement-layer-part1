// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Settlement Layer state machine — Part 1 states (per SawaSwap Core Protocol v0.11.2 §3 / §C.3.1)
/// @dev Enum ordering is part of the ABI; do not reorder between releases. Terminal states must remain last.
enum State {
    PoICommitted, // [1] Escrow Locked / PoI Committed — entry state
    ExecutionOpen, // [3] Execution Open / TW1
    EscalationL1, // [4B] Escalation Level 1 / TW2
    EscalationL2_DRP, // [5D] Escalation Level 2 / DRP / TW3
    Settled, // [5A or DRP-Settled] terminal — escrow released to beneficiary
    Reversed // [5C or DRP-Reversed] terminal — escrow returned to originator
}

/// @notice Direction of a SawaSwap transaction.
/// @dev CMM = Crypto → Mobile Money (User A → User C via Agent B);
///      MMC = Mobile Money → Crypto (User C → User A via Agent B).
///      Eligible claimant is fixed at PoI: CMM → User C, MMC → Agent B (per §C.2).
enum Direction {
    CMM,
    MMC
}

/// @notice Input bundle for `commitPoI`.
/// @dev `originator` is taken from `msg.sender`; `eligibleClaimant` is supplied by the originator
///      and matches the off-chain receiver per protocol §C.2.
struct PoIInput {
    address beneficiary;
    address eligibleClaimant;
    Direction direction;
    uint256 escrowAmount;
    bytes32 momoLegHash;
}

/// @notice Time-window configuration. Values in seconds.
/// @dev TW1 = execution window; TW2 = claim window (≤ 36h); TW3 = DRP resolution window (≤ 72h).
struct TimeWindows {
    uint64 tw1;
    uint64 tw2;
    uint64 tw3;
}

/// @notice On-chain record of a SawaSwap transaction at and beyond PoI commitment.
/// @dev `tw1`, `tw2`, `tw3` are locked at PoI per protocol §C.3.3 and do not move with admin
///      changes to the default windows post-commit.
struct Transaction {
    bytes32 stid;
    address originator;
    address beneficiary;
    address eligibleClaimant;
    Direction direction;
    uint256 escrowAmount;
    bytes32 momoLegHash;
    uint64 tw1;
    uint64 tw2;
    uint64 tw3;
    uint64 committedAt;
    State state;
    bool drpInvoked;
    bool terminalMoved;
}
