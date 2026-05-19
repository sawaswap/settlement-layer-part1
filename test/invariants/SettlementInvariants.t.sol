// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Settlement} from "../../src/Settlement.sol";
import {State, Transaction, TimeWindows} from "../../src/types/Types.sol";
import {IDRP} from "../../src/interfaces/IDRP.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDRP} from "../mocks/MockDRP.sol";
import {SettlementHandler} from "./SettlementHandler.sol";

/// @title SettlementInvariants — Part 1 invariant suite (M1)
/// @notice Four properties exercised by the handler-driven Foundry invariant runner. The full
///         property catalogue (including expected M2 expansion) lives in `TESTING.md`.
contract SettlementInvariants is Test {
    Settlement settlement;
    SettlementHandler handler;
    MockERC20 usdc;
    MockDRP drp;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        drp = new MockDRP();
        settlement = new Settlement(
            IERC20(address(usdc)),
            IDRP(address(drp)),
            address(this),
            TimeWindows({tw1: 30 minutes, tw2: 12 hours, tw3: 48 hours})
        );
        handler = new SettlementHandler(settlement, usdc);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SettlementHandler.commitPoI_bounded.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev P1 — Terminal absorbing. M1 has no transitions, so every committed transaction must
    ///      remain in `PoICommitted` and the `terminalMoved` flag must remain false.
    function invariant_terminalAbsorbing_M1AlwaysPoICommitted() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            Transaction memory txn = settlement.getTransaction(stid);
            assertEq(uint8(txn.state), uint8(State.PoICommitted), "M1 has no state transitions");
            assertFalse(txn.terminalMoved, "terminalMoved must remain false in M1");
            assertFalse(txn.drpInvoked, "drpInvoked must remain false in M1");
        }
    }

    /// @dev P2 — No transaction without commitPoI. Existence implies populated invariants.
    function invariant_noTransactionWithoutCommitPoI() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            assertTrue(settlement.transactionExists(stid), "stid must exist after handler success");
            Transaction memory txn = settlement.getTransaction(stid);
            assertGt(txn.committedAt, 0, "committedAt must be non-zero");
            assertTrue(txn.originator != address(0), "originator must be non-zero");
            assertTrue(txn.beneficiary != address(0), "beneficiary must be non-zero");
            assertTrue(txn.eligibleClaimant != address(0), "eligibleClaimant must be non-zero");
        }
    }

    /// @dev P3 — Escrow amount immutability. Stored amount equals what the handler passed.
    function invariant_escrowAmountMatchesCommitInput() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            Transaction memory txn = settlement.getTransaction(stid);
            assertGt(txn.escrowAmount, 0, "amount must be positive");
            assertEq(txn.escrowAmount, handler.expectedAmount(stid), "stored amount must match commit input");
        }
    }

    /// @dev P4 — Time windows locked at PoI. Even if the admin changes defaults afterwards, an
    ///      already-committed transaction must retain its commit-time TW1 / TW2 / TW3.
    function invariant_timeWindowsLockedAtCommit() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            Transaction memory txn = settlement.getTransaction(stid);
            assertEq(txn.tw1, handler.expectedTW1(stid), "tw1 must be locked at PoI");
            assertEq(txn.tw2, handler.expectedTW2(stid), "tw2 must be locked at PoI");
            assertEq(txn.tw3, handler.expectedTW3(stid), "tw3 must be locked at PoI");
        }
    }

    /// @dev P3' — Escrow accounting. The Settlement contract's USDC balance must equal the sum of
    ///      every active escrow (= every successful commitPoI), since M1+PR3 has no terminal-state
    ///      transitions that would release escrow. Once submit-PoR / claim / DRP land in later PRs,
    ///      this invariant generalises to `balance == Σ active escrows` where terminalMoved txns
    ///      no longer count toward the active set.
    function invariant_escrowBalanceEqualsTotalLocked() public view {
        assertEq(
            usdc.balanceOf(address(settlement)), handler.totalLocked(), "USDC balance must equal sum of locked escrows"
        );
    }
}
