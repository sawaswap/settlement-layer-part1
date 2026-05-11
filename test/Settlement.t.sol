// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Settlement} from "../src/Settlement.sol";
import {State, Direction, Transaction, TimeWindows, PoIInput} from "../src/types/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Settlement.t.sol — M1 unit and integration tests
/// @notice Covers the eight §D.2.2 acceptance bullets plus a bonus check that all M2 stubs revert.
contract SettlementTest is Test {
    Settlement settlement;
    MockERC20 usdc;

    address admin = makeAddr("admin");
    address originator = makeAddr("originator");
    address beneficiary = makeAddr("beneficiary");
    address claimant = makeAddr("claimant");
    address stranger = makeAddr("stranger");

    uint64 constant DEFAULT_TW1 = 30 minutes;
    uint64 constant DEFAULT_TW2 = 12 hours;
    uint64 constant DEFAULT_TW3 = 48 hours;

    uint256 constant DEFAULT_AMOUNT = 100e6; // 100 USDC (6 decimals)
    bytes32 constant DEFAULT_MOMO_HASH = keccak256("test-momo-leg");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        settlement = new Settlement(
            IERC20(address(usdc)), admin, TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
    }

    // ─── 1. Deployment ───────────────────────────────────────────────────────────────────────────

    function test_Deployment_SetsConstructorArgs() public view {
        assertEq(address(settlement.USDC()), address(usdc), "USDC address mismatch");
        assertTrue(settlement.hasRole(settlement.ADMIN_ROLE(), admin), "admin missing ADMIN_ROLE");
        assertTrue(settlement.hasRole(settlement.DEFAULT_ADMIN_ROLE(), admin), "admin missing DEFAULT_ADMIN_ROLE");

        TimeWindows memory tw = settlement.getDefaultTimeWindows();
        assertEq(tw.tw1, DEFAULT_TW1, "tw1 default mismatch");
        assertEq(tw.tw2, DEFAULT_TW2, "tw2 default mismatch");
        assertEq(tw.tw3, DEFAULT_TW3, "tw3 default mismatch");
    }

    function test_Deployment_RevertsOnZeroUSDC() public {
        vm.expectRevert(Settlement.InvalidAddress.selector);
        new Settlement(IERC20(address(0)), admin, TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3}));
    }

    function test_Deployment_RevertsOnZeroAdmin() public {
        vm.expectRevert(Settlement.InvalidAddress.selector);
        new Settlement(
            IERC20(address(usdc)), address(0), TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
    }

    function test_Deployment_RevertsOnZeroTimeWindow() public {
        vm.expectRevert(Settlement.InvalidTimeWindow.selector);
        new Settlement(IERC20(address(usdc)), admin, TimeWindows({tw1: 0, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3}));
    }

    // ─── 2. Configuration (Parameter Configuration Carve-Out, §C.3.7) ────────────────────────────

    function test_Configuration_AdminCanSetTimeWindows() public {
        uint64 newTW1 = 1 hours;
        uint64 newTW2 = 24 hours;
        uint64 newTW3 = 72 hours;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Settlement.TimeWindowsConfigured(newTW1, newTW2, newTW3, admin);
        settlement.setDefaultTimeWindows(newTW1, newTW2, newTW3);

        TimeWindows memory tw = settlement.getDefaultTimeWindows();
        assertEq(tw.tw1, newTW1);
        assertEq(tw.tw2, newTW2);
        assertEq(tw.tw3, newTW3);
    }

    function test_Configuration_NonAdminCannotSetTimeWindows() public {
        bytes32 role = settlement.ADMIN_ROLE(); // cache before prank — read would otherwise consume it
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        settlement.setDefaultTimeWindows(1 hours, 24 hours, 72 hours);
    }

    function test_Configuration_AdminCanSetRailPairProfile() public {
        bytes32 railPair = keccak256("CMM:USDC-MPESA");
        uint64 customTW1 = 3 hours;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Settlement.RailPairProfileSet(railPair, customTW1, admin);
        settlement.setRailPairProfile(railPair, customTW1);

        assertEq(settlement.getRailPairTW1(railPair), customTW1);
    }

    function test_Configuration_RevertsOnZeroTW() public {
        vm.prank(admin);
        vm.expectRevert(Settlement.InvalidTimeWindow.selector);
        settlement.setDefaultTimeWindows(0, DEFAULT_TW2, DEFAULT_TW3);
    }

    // ─── 3. State enumeration ────────────────────────────────────────────────────────────────────

    function test_StateEnumeration_OrderingMatches() public pure {
        // ABI ordering must remain stable across releases.
        assertEq(uint8(State.PoICommitted), 0, "PoICommitted must be 0");
        assertEq(uint8(State.ExecutionOpen), 1, "ExecutionOpen must be 1");
        assertEq(uint8(State.EscalationL1), 2, "EscalationL1 must be 2");
        assertEq(uint8(State.EscalationL2_DRP), 3, "EscalationL2_DRP must be 3");
        assertEq(uint8(State.Settled), 4, "Settled must be 4");
        assertEq(uint8(State.Reversed), 5, "Reversed must be 5");

        // Direction encoding.
        assertEq(uint8(Direction.CMM), 0);
        assertEq(uint8(Direction.MMC), 1);
    }

    // ─── 4. Transaction creation (commitPoI) ─────────────────────────────────────────────────────

    function test_CommitPoI_CreatesTransaction() public {
        PoIInput memory input = _defaultInput();

        vm.recordLogs();
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(input);

        assertTrue(stid != bytes32(0), "STID must be non-zero");
        assertTrue(settlement.transactionExists(stid), "transaction must exist");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Settlement.PoICommitted.selector) {
                assertEq(logs[i].topics[1], stid, "stid topic");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), originator, "originator topic");
                assertEq(address(uint160(uint256(logs[i].topics[3]))), beneficiary, "beneficiary topic");
                found = true;
                break;
            }
        }
        assertTrue(found, "PoICommitted event not emitted");
    }

    // ─── 5. State entry ──────────────────────────────────────────────────────────────────────────

    function test_StateEntry_PoICommittedIsInitialState() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.PoICommitted), "initial state must be PoICommitted");
        assertFalse(txn.drpInvoked, "drpInvoked must default false");
        assertFalse(txn.terminalMoved, "terminalMoved must default false");
    }

    // ─── 6. Transaction storage ──────────────────────────────────────────────────────────────────

    function test_TransactionStorage_PersistsAllFields() public {
        PoIInput memory input = _defaultInput();

        vm.warp(1_700_000_000);
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(input);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(txn.stid, stid);
        assertEq(txn.originator, originator);
        assertEq(txn.beneficiary, input.beneficiary);
        assertEq(txn.eligibleClaimant, input.eligibleClaimant);
        assertEq(uint8(txn.direction), uint8(input.direction));
        assertEq(txn.escrowAmount, input.escrowAmount);
        assertEq(txn.momoLegHash, input.momoLegHash);
        assertEq(txn.tw1, DEFAULT_TW1);
        assertEq(txn.tw2, DEFAULT_TW2);
        assertEq(txn.tw3, DEFAULT_TW3);
        assertEq(txn.committedAt, 1_700_000_000);
        assertEq(uint8(txn.state), uint8(State.PoICommitted));
    }

    function test_TransactionStorage_TWLockedAtPoI() public {
        // After commit, an admin change to defaults must not retroactively change stored windows.
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.prank(admin);
        settlement.setDefaultTimeWindows(1, 2, 3);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(txn.tw1, DEFAULT_TW1, "tw1 must be locked at PoI");
        assertEq(txn.tw2, DEFAULT_TW2, "tw2 must be locked at PoI");
        assertEq(txn.tw3, DEFAULT_TW3, "tw3 must be locked at PoI");
    }

    // ─── 7. Zero-amount revert ───────────────────────────────────────────────────────────────────

    function test_CommitPoI_RevertsOnZeroAmount() public {
        PoIInput memory input = _defaultInput();
        input.escrowAmount = 0;

        vm.prank(originator);
        vm.expectRevert(Settlement.ZeroAmount.selector);
        settlement.commitPoI(input);
    }

    function test_CommitPoI_RevertsOnZeroBeneficiary() public {
        PoIInput memory input = _defaultInput();
        input.beneficiary = address(0);

        vm.prank(originator);
        vm.expectRevert(Settlement.InvalidAddress.selector);
        settlement.commitPoI(input);
    }

    function test_CommitPoI_RevertsOnZeroClaimant() public {
        PoIInput memory input = _defaultInput();
        input.eligibleClaimant = address(0);

        vm.prank(originator);
        vm.expectRevert(Settlement.InvalidAddress.selector);
        settlement.commitPoI(input);
    }

    // ─── 8. Getter ───────────────────────────────────────────────────────────────────────────────

    function test_Getter_RevertsOnUnknownSTID() public {
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.getTransaction(bytes32(uint256(0xdead)));
    }

    function test_Getter_TransactionExistsReturnsTrue() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        assertTrue(settlement.transactionExists(stid));
        assertFalse(settlement.transactionExists(bytes32(uint256(0xdead))));
    }

    function test_Getter_NonceIncrementsPerOriginator() public {
        assertEq(settlement.getNonce(originator), 0);

        vm.prank(originator);
        settlement.commitPoI(_defaultInput());
        assertEq(settlement.getNonce(originator), 1);

        vm.prank(originator);
        settlement.commitPoI(_defaultInput());
        assertEq(settlement.getNonce(originator), 2);

        // Different originator has its own nonce series.
        assertEq(settlement.getNonce(stranger), 0);
    }

    // ─── 9. M2 stubs revert ──────────────────────────────────────────────────────────────────────

    function test_M2Stubs_RevertNotImplemented() public {
        vm.startPrank(originator);

        vm.expectRevert(Settlement.NotImplementedM1.selector);
        settlement.submitPoR(bytes32(0), "");

        vm.expectRevert(Settlement.NotImplementedM1.selector);
        settlement.submitClaim(bytes32(0), "");

        vm.expectRevert(Settlement.NotImplementedM1.selector);
        settlement.updateClaim(bytes32(0), "");

        vm.expectRevert(Settlement.NotImplementedM1.selector);
        settlement.invokeDRP(bytes32(0));

        vm.expectRevert(Settlement.NotImplementedM1.selector);
        settlement.settle(bytes32(0));

        vm.expectRevert(Settlement.NotImplementedM1.selector);
        settlement.reverse(bytes32(0));

        vm.stopPrank();
    }

    // ─── helpers ─────────────────────────────────────────────────────────────────────────────────

    function _defaultInput() internal view returns (PoIInput memory) {
        return PoIInput({
            beneficiary: beneficiary,
            eligibleClaimant: claimant,
            direction: Direction.CMM,
            escrowAmount: DEFAULT_AMOUNT,
            momoLegHash: DEFAULT_MOMO_HASH
        });
    }
}
