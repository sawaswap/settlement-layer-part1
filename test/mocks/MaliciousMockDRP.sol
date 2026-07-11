// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IDRP} from "../../src/interfaces/IDRP.sol";
import {Settlement} from "../../src/Settlement.sol";

/// @title MaliciousMockDRP — adversarial DRP harness exercising the reentrancy boundary
/// @notice On `resolve(stid)`, attempts to re-enter the Settlement Layer. By default it re-enters
///         via `invokeDRP(stid)` (same-function reentry); with `setReentryTarget(Target.PokeTW1)`
///         it re-enters via a DIFFERENT `nonReentrant` function (`pokeTW1`) to prove the guard is
///         a contract-wide single flag, not a per-function one (audit item 7). Either way the
///         Settlement's `nonReentrant` modifier (OZ ReentrancyGuard) must block the re-entry; the
///         test wired to this mock asserts the revert is the expected reentrancy guard error.
/// @dev Used exclusively in the reentrancy-boundary tests in `Settlement.t.sol` section 6.10.
///      `settlement` is set post-construction because the canonical Settlement instance takes
///      the DRP address as an immutable constructor argument; the cycle is broken by setting
///      the back-reference after Settlement is deployed.
contract MaliciousMockDRP is IDRP {
    /// @notice Which `nonReentrant` function the mock re-enters on `resolve`.
    /// @dev `InvokeDRP` (default = 0) preserves the original same-function reentry test; `PokeTW1`
    ///      exercises cross-function reentry into a different `nonReentrant` entry point.
    enum Target {
        InvokeDRP,
        PokeTW1
    }

    Settlement public settlement;
    bool public reentryAttempted;
    Target public reentryTarget;

    function setSettlement(address s) external {
        settlement = Settlement(s);
    }

    function setReentryTarget(Target t) external {
        reentryTarget = t;
    }

    /// @inheritdoc IDRP
    function resolve(bytes32 stid) external override returns (Outcome) {
        reentryAttempted = true;
        // The Settlement's `nonReentrant` modifier must block this re-entry regardless of which
        // entry point is chosen. The guard fires before the target function's own preconditions,
        // so a cross-function target reverts `ReentrancyGuardReentrantCall`, not its own state
        // guard. If the guard fails to fire, the wired test asserts on the resulting state to
        // catch the regression.
        if (reentryTarget == Target.PokeTW1) {
            settlement.pokeTW1(stid);
        } else {
            settlement.invokeDRP(stid);
        }
        return Outcome.Settled;
    }
}
