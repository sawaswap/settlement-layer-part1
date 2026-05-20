// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IDRP} from "../../src/interfaces/IDRP.sol";
import {Settlement} from "../../src/Settlement.sol";

/// @title MaliciousMockDRP — adversarial DRP harness exercising the reentrancy boundary
/// @notice On `resolve(stid)`, attempts to re-enter the Settlement Layer via `invokeDRP(stid)`.
///         The Settlement's `nonReentrant` modifier (OZ ReentrancyGuard) must block this; the
///         test wired to this mock asserts the revert is the expected reentrancy guard error.
/// @dev Used exclusively in the reentrancy-boundary test in `Settlement.t.sol` section 6.10.
///      `settlement` is set post-construction because the canonical Settlement instance takes
///      the DRP address as an immutable constructor argument; the cycle is broken by setting
///      the back-reference after Settlement is deployed.
contract MaliciousMockDRP is IDRP {
    Settlement public settlement;
    bool public reentryAttempted;

    function setSettlement(address s) external {
        settlement = Settlement(s);
    }

    /// @inheritdoc IDRP
    function resolve(bytes32 stid) external override returns (Outcome) {
        reentryAttempted = true;
        // The Settlement's `nonReentrant` modifier on `invokeDRP` must block this call. If the
        // guard fails to fire, the test that wires this mock asserts on the resulting state to
        // catch the regression.
        settlement.invokeDRP(stid);
        return Outcome.Settled;
    }
}
