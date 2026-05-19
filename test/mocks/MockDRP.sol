// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IDRP} from "../../src/interfaces/IDRP.sol";

/// @title MockDRP — configurable Dispute Resolution Protocol mock for Settlement tests
/// @notice Implements the frozen `IDRP` boundary interface (v0.11.2 §9 + addendum §2) without
///         executing any actual dispute-resolution logic. Tests configure the desired outcome
///         (or a reverting failure) per STID before driving `Settlement.invokeDRP`; this mock
///         then returns the preset value on the single permitted call.
/// @dev Out of Part-1 scope on the protocol side; this harness exists solely to exercise the
///      Settlement Layer's DRP boundary. The single-invocation guard (`called[stid]`) mirrors
///      the DRP's own hard constraint per the addendum: one resolution per STID, no replays.
contract MockDRP is IDRP {
    /// @notice Preset outcome to return on the next `resolve(stid)` call.
    mapping(bytes32 stid => Outcome) public preset;

    /// @notice If true, `resolve(stid)` reverts before returning. Used to exercise the
    ///         Settlement-side revert-rollback semantics on a failed DRP call.
    mapping(bytes32 stid => bool) public shouldRevert;

    /// @notice Tracks whether `resolve` has already fired for a given STID. Enforces the
    ///         single-invocation invariant; second call reverts.
    mapping(bytes32 stid => bool) public called;

    /// @notice Configure the outcome that `resolve(stid)` returns on its single permitted call.
    function setOutcome(bytes32 stid, Outcome outcome) external {
        preset[stid] = outcome;
    }

    /// @notice Configure `resolve(stid)` to revert instead of returning an outcome.
    function setRevert(bytes32 stid, bool revertFlag) external {
        shouldRevert[stid] = revertFlag;
    }

    /// @inheritdoc IDRP
    function resolve(bytes32 stid) external override returns (Outcome) {
        require(!called[stid], "MockDRP: already-resolved");
        called[stid] = true;
        if (shouldRevert[stid]) revert("MockDRP: configured-revert");
        return preset[stid];
    }
}
