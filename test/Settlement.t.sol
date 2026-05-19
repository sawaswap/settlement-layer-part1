// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Settlement} from "../src/Settlement.sol";
import {State, Direction, Transaction, TimeWindows, PoIInput} from "../src/types/Types.sol";
import {IDRP} from "../src/interfaces/IDRP.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDRP} from "./mocks/MockDRP.sol";
import {MaliciousMockDRP} from "./mocks/MaliciousMockDRP.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Settlement.t.sol — M1 unit and integration tests
/// @notice Covers the eight §D.2.2 acceptance bullets plus a bonus check that all M2 stubs revert.
contract SettlementTest is Test {
    Settlement settlement;
    MockERC20 usdc;
    MockDRP drp;

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
        drp = new MockDRP();
        settlement = new Settlement(
            IERC20(address(usdc)),
            IDRP(address(drp)),
            admin,
            TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
        // Default fixture: originator is funded and pre-approved for ten default commits' worth of
        // escrow. Tests that need to test the un-approved path (or insufficient balance) override.
        _fundAndApprove(originator, DEFAULT_AMOUNT * 10);
    }

    // ─── 1. Deployment ───────────────────────────────────────────────────────────────────────────

    function test_Deployment_SetsConstructorArgs() public view {
        assertEq(address(settlement.USDC()), address(usdc), "USDC address mismatch");
        assertEq(address(settlement.DRP()), address(drp), "DRP address mismatch");
        assertTrue(settlement.hasRole(settlement.ADMIN_ROLE(), admin), "admin missing ADMIN_ROLE");
        assertTrue(settlement.hasRole(settlement.DEFAULT_ADMIN_ROLE(), admin), "admin missing DEFAULT_ADMIN_ROLE");

        TimeWindows memory tw = settlement.getDefaultTimeWindows();
        assertEq(tw.tw1, DEFAULT_TW1, "tw1 default mismatch");
        assertEq(tw.tw2, DEFAULT_TW2, "tw2 default mismatch");
        assertEq(tw.tw3, DEFAULT_TW3, "tw3 default mismatch");
    }

    function test_Deployment_RevertsOnZeroUSDC() public {
        vm.expectRevert(Settlement.InvalidAddress.selector);
        new Settlement(
            IERC20(address(0)),
            IDRP(address(drp)),
            admin,
            TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
    }

    function test_Deployment_RevertsOnZeroDRP() public {
        vm.expectRevert(Settlement.InvalidAddress.selector);
        new Settlement(
            IERC20(address(usdc)),
            IDRP(address(0)),
            admin,
            TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
    }

    function test_Deployment_RevertsOnZeroAdmin() public {
        vm.expectRevert(Settlement.InvalidAddress.selector);
        new Settlement(
            IERC20(address(usdc)),
            IDRP(address(drp)),
            address(0),
            TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
    }

    function test_Deployment_RevertsOnZeroTimeWindow() public {
        vm.expectRevert(Settlement.InvalidTimeWindow.selector);
        new Settlement(
            IERC20(address(usdc)), IDRP(address(drp)), admin, TimeWindows({tw1: 0, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
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

    // ─── 6.5 Escrow lock at PoI (M2 — §D.2.3 D4 "Escrow locks at transaction creation / PoI commitment") ─

    /// @dev Happy path: a pre-approved originator commits, contract balance rises by `escrowAmount`,
    ///      originator balance falls by the same amount.
    function test_EscrowLock_LocksOnCommit() public {
        uint256 originatorBefore = usdc.balanceOf(originator);
        uint256 contractBefore = usdc.balanceOf(address(settlement));

        vm.prank(originator);
        settlement.commitPoI(_defaultInput());

        assertEq(usdc.balanceOf(originator), originatorBefore - DEFAULT_AMOUNT, "originator balance must drop");
        assertEq(usdc.balanceOf(address(settlement)), contractBefore + DEFAULT_AMOUNT, "contract balance must rise");
    }

    /// @dev Locked amount equals the `escrowAmount` field of the PoI input exactly, including for
    ///      a non-default amount.
    function test_EscrowLock_AmountMatchesInput() public {
        uint256 customAmount = 42_345_678; // 42.345678 USDC
        _fundAndApprove(stranger, customAmount);

        PoIInput memory input = _defaultInput();
        input.escrowAmount = customAmount;

        uint256 contractBefore = usdc.balanceOf(address(settlement));

        vm.prank(stranger);
        bytes32 stid = settlement.commitPoI(input);

        assertEq(usdc.balanceOf(address(settlement)) - contractBefore, customAmount, "locked delta must equal input");

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(txn.escrowAmount, customAmount, "stored escrowAmount must equal input");
    }

    /// @dev Without prior allowance, `commitPoI` reverts on the `safeTransferFrom` call and no
    ///      transaction record persists (full revert via CEI ordering and `nonReentrant`).
    function test_EscrowLock_RevertsWithoutAllowance() public {
        // `stranger` has neither balance nor allowance.
        PoIInput memory input = _defaultInput();

        vm.prank(stranger);
        vm.expectRevert(); // SafeERC20 wraps the underlying ERC20InsufficientAllowance / -Balance.
        settlement.commitPoI(input);

        // Nonce must not have moved (state changes reverted alongside the failing external call).
        assertEq(settlement.getNonce(stranger), 0, "nonce must not increment on reverted commitPoI");
    }

    /// @dev Two successful commits from the same originator each lock independently; contract
    ///      balance equals the sum of both `escrowAmount`s and each STID exists.
    function test_EscrowLock_AccumulatesAcrossCommits() public {
        uint256 contractBefore = usdc.balanceOf(address(settlement));

        vm.startPrank(originator);
        bytes32 stid1 = settlement.commitPoI(_defaultInput());
        bytes32 stid2 = settlement.commitPoI(_defaultInput());
        vm.stopPrank();

        assertTrue(stid1 != stid2, "STIDs must differ across commits");
        assertEq(usdc.balanceOf(address(settlement)) - contractBefore, DEFAULT_AMOUNT * 2, "balance must equal sum");
        assertTrue(settlement.transactionExists(stid1));
        assertTrue(settlement.transactionExists(stid2));
    }

    // ─── 6.6 PoR submission and Settled finality (M2 — §D.2.3 D4 "Valid PoR → Settled" + D6 PoR gate) ─

    /// @dev Happy path (CMM): originator commits, eligible claimant submits PoR within TW1.
    ///      State transitions to Settled, escrow released to beneficiary, terminalMoved set,
    ///      PoRSubmitted + StateChanged + Settled events emitted, porHash recorded.
    function test_SubmitPoR_CMM_EligibleClaimantSubmitsAndSettles() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 contractBefore = usdc.balanceOf(address(settlement));
        bytes memory porData = _defaultPoRData();

        vm.expectEmit(true, true, true, true);
        emit Settlement.PoRSubmitted(stid);
        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.PoICommitted, State.Settled);
        vm.expectEmit(true, true, true, true);
        emit Settlement.Settled(stid, beneficiary, DEFAULT_AMOUNT);

        vm.prank(claimant);
        settlement.submitPoR(stid, porData);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.Settled), "state must be Settled");
        assertTrue(txn.terminalMoved, "terminalMoved must be true");

        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore + DEFAULT_AMOUNT, "beneficiary must receive escrow");
        assertEq(usdc.balanceOf(address(settlement)), contractBefore - DEFAULT_AMOUNT, "contract balance must drop");

        assertEq(settlement.getPoRHash(stid), keccak256(porData), "porHash must equal keccak256(porData)");
    }

    /// @dev Happy path (MMC): direction-symmetric. Same submitter rule — eligibleClaimant submits.
    function test_SubmitPoR_MMC_EligibleClaimantSubmitsAndSettles() public {
        PoIInput memory input = _defaultInput();
        input.direction = Direction.MMC;

        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(input);

        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);

        vm.prank(claimant);
        settlement.submitPoR(stid, _defaultPoRData());

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.Settled), "state must be Settled");
        assertEq(uint8(txn.direction), uint8(Direction.MMC), "direction must be MMC");
        assertTrue(txn.terminalMoved);
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore + DEFAULT_AMOUNT, "beneficiary must receive escrow");
    }

    /// @dev Caller is not the recorded `eligibleClaimant` — must revert NotPoRSubmitter.
    function test_SubmitPoR_RevertsWhenCallerNotEligibleClaimant() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        // Originator is not the eligibleClaimant by construction (different addresses in setUp).
        vm.prank(originator);
        vm.expectRevert(Settlement.NotPoRSubmitter.selector);
        settlement.submitPoR(stid, _defaultPoRData());

        // Random stranger also blocked.
        vm.prank(stranger);
        vm.expectRevert(Settlement.NotPoRSubmitter.selector);
        settlement.submitPoR(stid, _defaultPoRData());
    }

    /// @dev Second submission after Settled — state guard fires, no double-settle, no double-pay.
    function test_SubmitPoR_RevertsWhenStateNotPoICommitted() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.prank(claimant);
        settlement.submitPoR(stid, _defaultPoRData());

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(Settlement.InvalidState.selector, uint8(State.PoICommitted), uint8(State.Settled))
        );
        settlement.submitPoR(stid, _defaultPoRData());
    }

    /// @dev `block.timestamp > committedAt + tw1` — TW1 window has closed, PoR no longer admissible.
    function test_SubmitPoR_RevertsWhenTW1Expired() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.prank(claimant);
        vm.expectRevert(Settlement.WindowExpired.selector);
        settlement.submitPoR(stid, _defaultPoRData());
    }

    /// @dev Empty payload — payload-shape precondition fails, revert InvalidPoRData.
    function test_SubmitPoR_RevertsOnEmptyData() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.prank(claimant);
        vm.expectRevert(Settlement.InvalidPoRData.selector);
        settlement.submitPoR(stid, "");
    }

    /// @dev Unknown STID — existence sentinel fails, revert TransactionNotFound.
    function test_SubmitPoR_RevertsOnUnknownStid() public {
        vm.prank(claimant);
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.submitPoR(bytes32(uint256(0xdeadbeef)), _defaultPoRData());
    }

    // ─── 6.7 Finality (M2 — §D.2.3 D4 "Escrow moves exactly once" + "Terminal outcome only Settled/Reversed") ─

    /// @dev Terminal absorbing: once a transaction is Settled, no further admission of PoR or any
    ///      other state-changing M2-implemented entry leaves it in a different state. The state
    ///      and terminalMoved flag remain pinned across attempts.
    function test_Finality_TerminalAbsorbing_SettledIsAbsorbing() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.prank(claimant);
        settlement.submitPoR(stid, _defaultPoRData());

        // Repeated submitPoR attempts all revert; state must remain Settled, terminalMoved true.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(claimant);
            vm.expectRevert();
            settlement.submitPoR(stid, _defaultPoRData());

            Transaction memory txn = settlement.getTransaction(stid);
            assertEq(uint8(txn.state), uint8(State.Settled), "Settled must remain absorbing");
            assertTrue(txn.terminalMoved, "terminalMoved must remain true");
        }
    }

    /// @dev Single-move: escrow leaves the contract exactly once. Beneficiary balance increases by
    ///      exactly `escrowAmount`, contract balance drops by the same amount, and the originator
    ///      balance is unchanged at settle time — their debit happens at commit, not at settle.
    function test_Finality_SingleMove_EscrowReleasedExactlyOnce() public {
        // Two independent commits; only the second one is settled.
        vm.startPrank(originator);
        settlement.commitPoI(_defaultInput());
        bytes32 stid2 = settlement.commitPoI(_defaultInput());
        vm.stopPrank();

        // Snapshot balances immediately before the settling call.
        uint256 originatorBefore = usdc.balanceOf(originator);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 contractBefore = usdc.balanceOf(address(settlement));

        vm.prank(claimant);
        settlement.submitPoR(stid2, _defaultPoRData());

        // Exactly one DEFAULT_AMOUNT moved: beneficiary up by one, contract down by one.
        assertEq(usdc.balanceOf(beneficiary) - beneficiaryBefore, DEFAULT_AMOUNT, "beneficiary up by exactly one");
        assertEq(contractBefore - usdc.balanceOf(address(settlement)), DEFAULT_AMOUNT, "contract down by exactly one");

        // Originator balance unchanged at settle time — their funds were debited at commitPoI.
        assertEq(usdc.balanceOf(originator), originatorBefore, "originator balance must not change at settle");

        // The other still-active commit's escrow remains in the contract.
        assertEq(usdc.balanceOf(address(settlement)), DEFAULT_AMOUNT, "first commit's escrow must still be locked");
    }

    // ─── 6.8 TW1 expiry escalation (M2 — §D.2.3 D5 "TW1 expiry without valid PoR opens escalation path") ─

    /// @dev Before TW1 elapses, no party — claimant, originator, or stranger — can escalate.
    ///      The poker reverts `EscalationNotDue` and the transaction stays in `PoICommitted`.
    function test_PokeTW1_RevertsBeforeTW1Expiry() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.prank(stranger);
        vm.expectRevert(Settlement.EscalationNotDue.selector);
        settlement.pokeTW1(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.PoICommitted), "state must remain PoICommitted before TW1 expiry");
    }

    /// @dev Any caller may drive the escalation once TW1 has elapsed. The transition emits
    ///      `StateChanged(PoICommitted, EscalationL1)` and leaves `terminalMoved` / `drpInvoked`
    ///      untouched — no escrow has moved and the DRP has not been invoked.
    function test_PokeTW1_TransitionsToEscalationL1AfterExpiry() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.PoICommitted, State.EscalationL1);
        vm.prank(stranger);
        settlement.pokeTW1(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1), "state must advance to EscalationL1");
        assertFalse(txn.terminalMoved, "terminalMoved must remain false - no escrow movement on escalation");
        assertFalse(txn.drpInvoked, "drpInvoked must remain false - DRP not invoked on escalation");
    }

    /// @dev Once escalated, the transaction is no longer in `PoICommitted`; a second poke reverts
    ///      `InvalidState(PoICommitted, EscalationL1)`. This is the same shape `submitPoR` uses
    ///      for its state guard.
    function test_PokeTW1_RevertsFromNonPoICommittedState() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.prank(stranger);
        settlement.pokeTW1(stid);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settlement.InvalidState.selector, uint8(State.PoICommitted), uint8(State.EscalationL1)
            )
        );
        settlement.pokeTW1(stid);
    }

    /// @dev Existence sentinel applies uniformly across M2 entries: unknown STID → `TransactionNotFound`.
    function test_PokeTW1_RevertsOnUnknownStid() public {
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.pokeTW1(bytes32(uint256(0xdeadbeef)));
    }

    // ─── 6.9 Claim submission and TW2 default-reverse (M2 — §D.2.3 D7 "Claim submission and update" + D5 TW2 default-reverse) ─

    /// @dev Happy path for CMM direction. After TW1 elapses, the eligible claimant files a claim.
    ///      The internal lazy `_expireTW1IfDue` drives the state from `PoICommitted` to
    ///      `EscalationL1` and the claim hash is stored in `_claimHash[stid]`. `ClaimSubmitted` is
    ///      emitted; `terminalMoved` stays false because no escrow has moved.
    function test_SubmitClaim_HappyPath_CMM() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.expectEmit(true, true, true, true);
        emit Settlement.ClaimSubmitted(stid, claimant);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1), "state must advance to EscalationL1 via lazy escalate");
        assertEq(settlement.getClaimHash(stid), keccak256(_defaultClaimData()), "claim hash must be stored");
        assertFalse(txn.terminalMoved, "terminalMoved must remain false - no escrow movement on claim submission");
    }

    /// @dev MMC direction symmetry: identical flow with `Direction.MMC` and a distinct
    ///      eligible-claimant address. The eligibility predicate is direction-agnostic and reads
    ///      strictly from `Transaction.eligibleClaimant`, regardless of the rail direction.
    function test_SubmitClaim_HappyPath_MMC() public {
        address mmcClaimant = makeAddr("mmcClaimant");
        PoIInput memory input = _defaultInput();
        input.direction = Direction.MMC;
        input.eligibleClaimant = mmcClaimant;

        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(input);

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.expectEmit(true, true, true, true);
        emit Settlement.ClaimSubmitted(stid, mmcClaimant);
        vm.prank(mmcClaimant);
        settlement.submitClaim(stid, _defaultClaimData());

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1));
        assertEq(settlement.getClaimHash(stid), keccak256(_defaultClaimData()));
    }

    /// @dev Eligibility guard: a stranger cannot file a claim even after TW1 has elapsed. The
    ///      lazy-escalate side effect from `_expireTW1IfDue` is rolled back together with the
    ///      revert, so the transaction's state remains `PoICommitted` after the failed call.
    function test_SubmitClaim_RevertsWhenCallerNotEligibleClaimant() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.prank(stranger);
        vm.expectRevert(Settlement.NotEligibleClaimant.selector);
        settlement.submitClaim(stid, _defaultClaimData());

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(
            uint8(txn.state), uint8(State.PoICommitted), "revert rolls back lazy escalate; state remains PoICommitted"
        );
        assertEq(settlement.getClaimHash(stid), bytes32(0), "no claim must be recorded on rejected call");
    }

    /// @dev Update path: while TW2 is still open and before DRP would be invoked (PR #7), the
    ///      eligible claimant may refine the claim payload. The stored claim hash advances to the
    ///      new payload's keccak256 and `ClaimUpdated` is emitted; state remains `EscalationL1`.
    function test_UpdateClaim_BeforeTW2Expiry_Works() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        bytes memory updatedClaim = bytes("claim-payload-v2");

        vm.expectEmit(true, true, true, true);
        emit Settlement.ClaimUpdated(stid);
        vm.prank(claimant);
        settlement.updateClaim(stid, updatedClaim);

        assertEq(settlement.getClaimHash(stid), keccak256(updatedClaim), "claim hash must reflect the update");
        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1), "state must remain EscalationL1 across update");
    }

    /// @dev Time-window guard. Once TW2 has elapsed, the claim is locked in and `updateClaim`
    ///      reverts `WindowExpired`. This is the M2-side substitute for the spec's
    ///      "before claim acceptance" mutability boundary — the post-DRP-invocation lockout
    ///      lands separately with `invokeDRP` in PR #7.
    function test_UpdateClaim_RevertsAfterTW2Expiry() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        // Advance to past TW1 + TW2 absolute window.
        vm.warp(block.timestamp + DEFAULT_TW2 + 1);

        vm.prank(claimant);
        vm.expectRevert(Settlement.WindowExpired.selector);
        settlement.updateClaim(stid, bytes("too-late-update"));

        assertEq(
            settlement.getClaimHash(stid),
            keccak256(_defaultClaimData()),
            "original claim hash must be preserved on rejected update"
        );
    }

    /// @dev Default-reverse path. TW1 + TW2 elapse with no claim on record; a permissionless
    ///      `expireTW2` call drives the transaction from `PoICommitted` directly to `Reversed`
    ///      (the entry-point lazy escalate transitions to `EscalationL1` on the way), and
    ///      `_finalizeReversed` atomically returns escrow to the originator. Two `StateChanged`
    ///      events are emitted in one tx — `(PoICommitted, EscalationL1)` and
    ///      `(EscalationL1, Reversed)` — preserving the lifecycle audit trail.
    function test_ExpireTW2_NoClaim_DefaultReverses() public {
        uint256 originatorBefore = usdc.balanceOf(originator);

        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        // Originator was debited by commit; verify before the reverse fires.
        assertEq(usdc.balanceOf(originator), originatorBefore - DEFAULT_AMOUNT, "originator debited at commit");
        assertEq(usdc.balanceOf(address(settlement)), DEFAULT_AMOUNT, "escrow held in contract before expireTW2");

        // Advance past TW1 + TW2 absolute window.
        vm.warp(block.timestamp + DEFAULT_TW1 + DEFAULT_TW2 + 1);

        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.PoICommitted, State.EscalationL1);
        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.EscalationL1, State.Reversed);
        vm.expectEmit(true, true, true, true);
        emit Settlement.Reversed(stid, originator, DEFAULT_AMOUNT);

        vm.prank(stranger);
        settlement.expireTW2(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.Reversed), "state must reach Reversed terminal");
        assertTrue(txn.terminalMoved, "terminalMoved must be set on default-reverse finalisation");
        assertEq(usdc.balanceOf(originator), originatorBefore, "originator restored to pre-commit balance");
        assertEq(usdc.balanceOf(address(settlement)), 0, "no escrow remains in contract after default-reverse");
    }

    /// @dev Empty `claimData` is rejected at the structural-validation gate, before the lazy
    ///      escalate or any other state mutation. Reverts `InvalidClaimData`.
    function test_SubmitClaim_RevertsOnEmptyClaimData() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.prank(claimant);
        vm.expectRevert(Settlement.InvalidClaimData.selector);
        settlement.submitClaim(stid, "");

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.PoICommitted), "state must not advance on rejected call");
    }

    /// @dev Existence sentinel: unknown STID → `TransactionNotFound`. Mirrors the M1-era pattern
    ///      applied uniformly across every M2 external entry.
    function test_SubmitClaim_RevertsOnUnknownStid() public {
        vm.prank(claimant);
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.submitClaim(bytes32(uint256(0xdeadbeef)), _defaultClaimData());
    }

    /// @dev Window guard: once TW1 + TW2 has elapsed without a prior claim, the eligible claimant
    ///      can no longer file the first claim — the path is closed and the transaction must
    ///      default-reverse via `expireTW2`. Reverts `WindowExpired`; the lazy escalate side
    ///      effect rolls back together with the revert.
    function test_SubmitClaim_RevertsAfterTW2Expiry() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + DEFAULT_TW2 + 1);

        vm.prank(claimant);
        vm.expectRevert(Settlement.WindowExpired.selector);
        settlement.submitClaim(stid, _defaultClaimData());

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.PoICommitted), "revert rolls back lazy escalate");
        assertEq(settlement.getClaimHash(stid), bytes32(0));
    }

    /// @dev Single-submit invariant: a second `submitClaim` after the first reverts
    ///      `ClaimAlreadyExists`. Subsequent modifications must go through `updateClaim`.
    ///      Originally-stored claim hash is preserved.
    function test_SubmitClaim_RevertsOnDuplicate() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        bytes memory secondClaim = bytes("second-claim-attempt");
        vm.prank(claimant);
        vm.expectRevert(Settlement.ClaimAlreadyExists.selector);
        settlement.submitClaim(stid, secondClaim);

        assertEq(
            settlement.getClaimHash(stid),
            keccak256(_defaultClaimData()),
            "first claim hash preserved on duplicate-submit revert"
        );
    }

    /// @dev Symmetric empty-payload guard on `updateClaim`. Reverts `InvalidClaimData`.
    function test_UpdateClaim_RevertsOnEmptyClaimData() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        vm.prank(claimant);
        vm.expectRevert(Settlement.InvalidClaimData.selector);
        settlement.updateClaim(stid, "");

        assertEq(settlement.getClaimHash(stid), keccak256(_defaultClaimData()), "original claim hash preserved");
    }

    /// @dev Symmetric existence guard on `updateClaim`. Reverts `TransactionNotFound`.
    function test_UpdateClaim_RevertsOnUnknownStid() public {
        vm.prank(claimant);
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.updateClaim(bytes32(uint256(0xdeadbeef)), _defaultClaimData());
    }

    /// @dev Symmetric eligibility guard on `updateClaim`. A stranger cannot mutate the claim hash
    ///      even after the eligible claimant has filed the initial submission. Reverts
    ///      `NotEligibleClaimant`; the previously-stored claim hash is preserved.
    function test_UpdateClaim_RevertsWhenCallerNotEligibleClaimant() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        vm.prank(stranger);
        vm.expectRevert(Settlement.NotEligibleClaimant.selector);
        settlement.updateClaim(stid, bytes("stranger-tampering-attempt"));

        assertEq(settlement.getClaimHash(stid), keccak256(_defaultClaimData()), "original claim hash preserved");
    }

    /// @dev Claim-presence guard on `updateClaim`. Once `pokeTW1` (PR #5) has driven the state to
    ///      `EscalationL1` but no prior `submitClaim` has fired, the eligible claimant cannot
    ///      `updateClaim` directly — `submitClaim` must come first. Reverts `NoClaimToUpdate`.
    function test_UpdateClaim_RevertsWhenNoPriorClaim() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        // Drive state to EscalationL1 via the permissionless TW1 poker without filing a claim.
        vm.prank(stranger);
        settlement.pokeTW1(stid);

        vm.prank(claimant);
        vm.expectRevert(Settlement.NoClaimToUpdate.selector);
        settlement.updateClaim(stid, _defaultClaimData());

        assertEq(settlement.getClaimHash(stid), bytes32(0), "no claim hash recorded on rejected updateClaim");
    }

    /// @dev Window guard on `expireTW2`. Before the TW1 + TW2 absolute window has elapsed, the
    ///      default-reverse path is not yet eligible to fire and the poker reverts
    ///      `EscalationNotDue`. The lazy escalate from `PoICommitted` rolls back with the revert
    ///      so state remains `PoICommitted`. Same shape as `pokeTW1`'s before-window revert.
    function test_ExpireTW2_RevertsBeforeTW2Expiry() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        // Past TW1 but not past TW1+TW2.
        vm.warp(block.timestamp + DEFAULT_TW1 + 1);

        vm.prank(stranger);
        vm.expectRevert(Settlement.EscalationNotDue.selector);
        settlement.expireTW2(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.PoICommitted), "revert rolls back lazy escalate");
    }

    /// @dev Claim-aware guard on `expireTW2`. When a claim exists at TW2 expiry, the
    ///      default-reverse path is preempted by the DRP route (`invokeDRP` in PR #7) and
    ///      `expireTW2` reverts `ClaimPending` to surface the misuse.
    function test_ExpireTW2_RevertsWhenClaimExists() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());

        // Advance past TW1 + TW2 absolute window.
        vm.warp(block.timestamp + DEFAULT_TW2 + 1);

        vm.prank(stranger);
        vm.expectRevert(Settlement.ClaimPending.selector);
        settlement.expireTW2(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1), "state remains EscalationL1 - DRP path pending");
        assertFalse(txn.terminalMoved, "terminalMoved must remain false - no escrow movement");
        assertEq(settlement.getClaimHash(stid), keccak256(_defaultClaimData()), "claim hash preserved");
    }

    /// @dev Symmetric existence guard on `expireTW2`. Reverts `TransactionNotFound`.
    function test_ExpireTW2_RevertsOnUnknownStid() public {
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.expireTW2(bytes32(uint256(0xdeadbeef)));
    }

    // ─── 6.10 DRP boundary and TW3 default-reverse (M2 — §D.2.3 D8 "DRP frozen interface + mock harness" + D5 TW3) ─

    /// @dev Happy path with DRP returning `Settled`. The claim was filed in TW2; `invokeDRP` drives
    ///      `EscalationL1` → `EscalationL2_DRP`, calls the mock with the preset outcome, and
    ///      atomically finalises to `Settled` with escrow released to the beneficiary.
    function test_InvokeDRP_OutcomeSettled_ReleasesEscrowToBeneficiary() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();
        drp.setOutcome(stid, IDRP.Outcome.Settled);

        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 contractBefore = usdc.balanceOf(address(settlement));

        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.EscalationL1, State.EscalationL2_DRP);
        vm.expectEmit(true, true, true, true);
        emit Settlement.DRPInvoked(stid);
        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.EscalationL2_DRP, State.Settled);
        vm.expectEmit(true, true, true, true);
        emit Settlement.Settled(stid, beneficiary, DEFAULT_AMOUNT);

        vm.prank(claimant);
        settlement.invokeDRP(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.Settled), "state must reach Settled terminal");
        assertTrue(txn.drpInvoked, "drpInvoked must be set");
        assertTrue(txn.terminalMoved, "terminalMoved must be set on finalisation");
        assertEq(usdc.balanceOf(beneficiary) - beneficiaryBefore, DEFAULT_AMOUNT, "beneficiary credited");
        assertEq(contractBefore - usdc.balanceOf(address(settlement)), DEFAULT_AMOUNT, "escrow released");
        assertTrue(drp.called(stid), "DRP marked as called");
    }

    /// @dev Mirror of the Settled-outcome path: DRP returns `Reversed`, escrow goes back to the
    ///      originator via `_finalizeReversed`. Same CEI / event sequence, mirrored terminal side.
    function test_InvokeDRP_OutcomeReversed_ReturnsEscrowToOriginator() public {
        uint256 originatorBefore = usdc.balanceOf(originator);
        bytes32 stid = _setUpInEscalationL1WithClaim();
        drp.setOutcome(stid, IDRP.Outcome.Reversed);

        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.EscalationL1, State.EscalationL2_DRP);
        vm.expectEmit(true, true, true, true);
        emit Settlement.DRPInvoked(stid);
        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.EscalationL2_DRP, State.Reversed);
        vm.expectEmit(true, true, true, true);
        emit Settlement.Reversed(stid, originator, DEFAULT_AMOUNT);

        vm.prank(claimant);
        settlement.invokeDRP(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.Reversed), "state must reach Reversed terminal");
        assertTrue(txn.drpInvoked, "drpInvoked must be set");
        assertTrue(txn.terminalMoved, "terminalMoved must be set on finalisation");
        assertEq(usdc.balanceOf(originator), originatorBefore, "originator restored to pre-commit balance");
    }

    /// @dev Single-invocation guard. Even after a successful resolution, the state has moved past
    ///      `EscalationL1` so the state guard fires first; `DRPAlreadyInvoked` is unreachable in
    ///      practice but documented as a defence-in-depth secondary guard.
    function test_InvokeDRP_RevertsOnSecondInvocation_FromTerminalState() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();
        drp.setOutcome(stid, IDRP.Outcome.Settled);

        vm.prank(claimant);
        settlement.invokeDRP(stid);

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(Settlement.InvalidState.selector, uint8(State.EscalationL1), uint8(State.Settled))
        );
        settlement.invokeDRP(stid);
    }

    /// @dev DRP boundary requires a claim on record; calling `invokeDRP` after `pokeTW1` but
    ///      without `submitClaim` reverts `NoClaim`.
    function test_InvokeDRP_RevertsWithoutClaim() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());
        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(stranger);
        settlement.pokeTW1(stid);

        vm.prank(claimant);
        vm.expectRevert(Settlement.NoClaim.selector);
        settlement.invokeDRP(stid);
    }

    /// @dev Eligibility guard: only the recorded `eligibleClaimant` can cross the DRP boundary.
    function test_InvokeDRP_RevertsWhenCallerNotEligibleClaimant() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();
        drp.setOutcome(stid, IDRP.Outcome.Settled);

        vm.prank(stranger);
        vm.expectRevert(Settlement.NotEligibleClaimant.selector);
        settlement.invokeDRP(stid);
    }

    /// @dev State guard: `invokeDRP` requires state == `EscalationL1`. Calling on a fresh
    ///      `PoICommitted` transaction reverts `InvalidState`.
    function test_InvokeDRP_RevertsFromPoICommittedState() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settlement.InvalidState.selector, uint8(State.EscalationL1), uint8(State.PoICommitted)
            )
        );
        settlement.invokeDRP(stid);
    }

    /// @dev Window guard: once TW1 + TW2 + TW3 has elapsed, the DRP path closes and the resolution
    ///      route is `expireTW3` (default-reverse). `invokeDRP` reverts `WindowExpired`.
    function test_InvokeDRP_RevertsAfterTW3Window() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();
        drp.setOutcome(stid, IDRP.Outcome.Settled);

        // Advance past the full TW1+TW2+TW3 envelope.
        vm.warp(block.timestamp + DEFAULT_TW2 + DEFAULT_TW3 + 1);

        vm.prank(claimant);
        vm.expectRevert(Settlement.WindowExpired.selector);
        settlement.invokeDRP(stid);
    }

    /// @dev Existence guard: unknown STID → `TransactionNotFound`. Mirrors the M1-era pattern.
    function test_InvokeDRP_RevertsOnUnknownStid() public {
        vm.prank(claimant);
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.invokeDRP(bytes32(uint256(0xdeadbeef)));
    }

    /// @dev DRP revert propagates atomically. When the DRP is configured to revert, the entire
    ///      `invokeDRP` call rolls back including the `EscalationL2_DRP` state transition and the
    ///      `drpInvoked` flag, leaving the transaction at `EscalationL1` ready for another attempt
    ///      (or eventual `expireTW3` after the window).
    function test_InvokeDRP_RevertsWhenDRPReverts() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();
        drp.setRevert(stid, true);

        vm.prank(claimant);
        vm.expectRevert(bytes("MockDRP: configured-revert"));
        settlement.invokeDRP(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1), "state stays EscalationL1 - DRP revert rolled back");
        assertFalse(txn.drpInvoked, "drpInvoked stays false on DRP-revert rollback");
    }

    /// @dev TW3 default-reverse happy path. The MockDRP resolves synchronously, so the live
    ///      scenario where `invokeDRP` transitions to `EscalationL2_DRP` but the DRP does not
    ///      return within TW3 cannot be reached through the public surface alone. We construct
    ///      the state directly via `vm.store` to exercise `expireTW3`'s own guards and finalisation
    ///      path; the field-level state mutation pattern that lands transactions in
    ///      `EscalationL2_DRP` is itself covered by the `OutcomeReversed` test above (same
    ///      `_finalizeReversed` helper). The invariant suite in PR #8 will exercise this path
    ///      through the handler's stateful sequencing.
    function test_ExpireTW3_NoOutcome_DefaultReverses() public {
        uint256 originatorBefore = usdc.balanceOf(originator);
        bytes32 stid = _setUpInEscalationL1WithClaim();

        // Manually transition the transaction to `EscalationL2_DRP` + `drpInvoked=true` via
        // direct storage write. The Transaction struct packs `state` (offset 0) + `drpInvoked`
        // (offset 1) + `terminalMoved` (offset 2) into one slot at struct-offset +7. The base
        // slot for `_txs[stid]` is `keccak256(stid, slot-of-_txs)`. `_txs` is the fifth contract
        // storage slot (after AccessControl `_roles`, ReentrancyGuard `_status`, `_defaultTW`,
        // `_railPairTW1`) — slot index 4. The packed-slot value `0x0103` sets state=3
        // (EscalationL2_DRP), drpInvoked=1, terminalMoved=0.
        uint256 txsSlot = uint256(keccak256(abi.encode(stid, uint256(4))));
        uint256 packedSlot = txsSlot + 7;
        vm.store(address(settlement), bytes32(packedSlot), bytes32(uint256(0x0103)));

        // Verify the manual injection placed the transaction in the expected state.
        Transaction memory injected = settlement.getTransaction(stid);
        assertEq(uint8(injected.state), uint8(State.EscalationL2_DRP), "state injected correctly");
        assertTrue(injected.drpInvoked, "drpInvoked injected correctly");
        assertFalse(injected.terminalMoved, "terminalMoved must remain false before expireTW3");

        // Advance past TW1+TW2+TW3 absolute window.
        vm.warp(block.timestamp + DEFAULT_TW2 + DEFAULT_TW3 + 1);

        vm.expectEmit(true, true, true, true);
        emit Settlement.StateChanged(stid, State.EscalationL2_DRP, State.Reversed);
        vm.expectEmit(true, true, true, true);
        emit Settlement.Reversed(stid, originator, DEFAULT_AMOUNT);

        vm.prank(stranger);
        settlement.expireTW3(stid);

        Transaction memory txn = settlement.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.Reversed), "state must reach Reversed terminal");
        assertTrue(txn.terminalMoved, "terminalMoved must be set on default-reverse finalisation");
        assertEq(usdc.balanceOf(originator), originatorBefore, "originator restored to pre-commit balance");
        assertEq(usdc.balanceOf(address(settlement)), 0, "no escrow remains in contract after default-reverse");
    }

    /// @dev Window guard on `expireTW3`. Before TW1+TW2+TW3 has elapsed, the default-reverse path
    ///      is not yet eligible to fire and the poker reverts `EscalationNotDue`. Uses the same
    ///      direct-storage state injection pattern as the happy-path test above.
    function test_ExpireTW3_RevertsBeforeWindow() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();

        // Inject EscalationL2_DRP state (see happy-path test for slot computation).
        uint256 txsSlot = uint256(keccak256(abi.encode(stid, uint256(4))));
        vm.store(address(settlement), bytes32(txsSlot + 7), bytes32(uint256(0x0103)));

        // Past TW1 + TW2 but NOT past TW3.
        vm.warp(block.timestamp + DEFAULT_TW2);

        vm.prank(stranger);
        vm.expectRevert(Settlement.EscalationNotDue.selector);
        settlement.expireTW3(stid);
    }

    /// @dev State guard on `expireTW3` from `PoICommitted`. Reverts `InvalidState` before the
    ///      window check.
    function test_ExpireTW3_RevertsFromNonDRPState_PoICommitted() public {
        vm.prank(originator);
        bytes32 stid = settlement.commitPoI(_defaultInput());

        // Past TW3 absolute envelope.
        vm.warp(block.timestamp + DEFAULT_TW1 + DEFAULT_TW2 + DEFAULT_TW3 + 1);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settlement.InvalidState.selector, uint8(State.EscalationL2_DRP), uint8(State.PoICommitted)
            )
        );
        settlement.expireTW3(stid);
    }

    /// @dev Symmetric state-guard test on `expireTW3` from `EscalationL1` (claim filed but DRP not
    ///      invoked). The path forward in that case is `invokeDRP` or `expireTW2`, not `expireTW3`.
    function test_ExpireTW3_RevertsFromEscalationL1State() public {
        bytes32 stid = _setUpInEscalationL1WithClaim();

        vm.warp(block.timestamp + DEFAULT_TW2 + DEFAULT_TW3 + 1);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settlement.InvalidState.selector, uint8(State.EscalationL2_DRP), uint8(State.EscalationL1)
            )
        );
        settlement.expireTW3(stid);
    }

    /// @dev Existence guard: unknown STID → `TransactionNotFound`.
    function test_ExpireTW3_RevertsOnUnknownStid() public {
        vm.expectRevert(Settlement.TransactionNotFound.selector);
        settlement.expireTW3(bytes32(uint256(0xdeadbeef)));
    }

    /// @dev Reentrancy boundary. Wires a malicious DRP that attempts to call back into
    ///      `Settlement.invokeDRP` from within its own `resolve()`. The Settlement's
    ///      `nonReentrant` modifier (OZ ReentrancyGuard v5) must block the re-entry; the
    ///      attempted `resolve()` reverts with `ReentrancyGuardReentrantCall`, which in turn
    ///      reverts the entire outer `invokeDRP` call (state mutation rolled back).
    function test_InvokeDRP_NonReentrant_BlocksReentryViaMaliciousDRP() public {
        MaliciousMockDRP maliciousDrp = new MaliciousMockDRP();
        Settlement settlementMal = new Settlement(
            IERC20(address(usdc)),
            IDRP(address(maliciousDrp)),
            admin,
            TimeWindows({tw1: DEFAULT_TW1, tw2: DEFAULT_TW2, tw3: DEFAULT_TW3})
        );
        maliciousDrp.setSettlement(address(settlementMal));

        // Drive the malicious-instance transaction into EscalationL1 with a claim. The default
        // fixture's `_fundAndApprove` targets the canonical `settlement` instance; here we need
        // an allowance against `settlementMal`, so inline the approval.
        usdc.mint(originator, DEFAULT_AMOUNT);
        vm.prank(originator);
        usdc.approve(address(settlementMal), DEFAULT_AMOUNT);

        vm.prank(originator);
        bytes32 stid = settlementMal.commitPoI(_defaultInput());
        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(stranger);
        settlementMal.pokeTW1(stid);
        vm.prank(claimant);
        settlementMal.submitClaim(stid, _defaultClaimData());

        // invokeDRP triggers maliciousDrp.resolve, which tries to re-enter. The outer call
        // reverts; OZ ReentrancyGuard v5 emits a `ReentrancyGuardReentrantCall` selector that
        // propagates out through the malicious DRP's own `resolve` call.
        vm.prank(claimant);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        settlementMal.invokeDRP(stid);

        // State must remain at EscalationL1 (full revert rolled back the EscalationL2_DRP
        // transition that occurred before the external call). The `reentryAttempted` flag on the
        // malicious mock is also rolled back as part of the same revert frame, so we verify the
        // reentrancy attempt indirectly through the specific `ReentrancyGuardReentrantCall`
        // selector that `vm.expectRevert` matched above.
        Transaction memory txn = settlementMal.getTransaction(stid);
        assertEq(uint8(txn.state), uint8(State.EscalationL1), "state remains EscalationL1 - revert rolled back");
        assertFalse(txn.drpInvoked, "drpInvoked stays false on reentrancy-blocked attempt");
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

    // ─── 9. Remaining M2 stubs revert ────────────────────────────────────────────────────────────

    function test_RemainingM2Stubs_RevertNotImplemented() public {
        // `submitPoR` (PR #4), `submitClaim` / `updateClaim` / `expireTW2` (PR #6), and
        // `invokeDRP` / `expireTW3` (PR #7) are all implemented and covered by their own sections.
        // Only `settle` / `reverse` remain as reverting stubs per the 15 May ratified decision to
        // drop the external recovery-hatch track (unreachable under SafeERC20 atomic-revert
        // semantics; kept only as ABI placeholders).
        vm.startPrank(originator);

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

    /// @dev Mints `amount` of USDC to `user` and sets allowance for the Settlement contract to the
    ///      same amount. Used by every commit-path test; tests of the un-funded / un-approved path
    ///      simply skip the call.
    function _fundAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(settlement), amount);
    }

    /// @dev Canonical PoR payload used across the PoR test suite. The contract only enforces
    ///      non-emptiness in M2; payload semantics are out of Part-1 scope.
    function _defaultPoRData() internal pure returns (bytes memory) {
        return bytes("por-payload-v1");
    }

    /// @dev Canonical claim payload used across the claim test suite. As with PoR, the contract
    ///      enforces only non-emptiness in M2; payload semantics are out of Part-1 scope and
    ///      deferred to the off-chain pipeline / DRP layer.
    function _defaultClaimData() internal pure returns (bytes memory) {
        return bytes("claim-payload-v1");
    }

    /// @dev Drives the default fixture transaction through `commitPoI` + `pokeTW1` + `submitClaim`
    ///      so it is positioned at `EscalationL1` with a claim on record. Returns the STID. Used
    ///      by the DRP-boundary test suite (section 6.10) as the standard precondition.
    function _setUpInEscalationL1WithClaim() internal returns (bytes32 stid) {
        vm.prank(originator);
        stid = settlement.commitPoI(_defaultInput());

        vm.warp(block.timestamp + DEFAULT_TW1 + 1);
        vm.prank(stranger);
        settlement.pokeTW1(stid);

        vm.prank(claimant);
        settlement.submitClaim(stid, _defaultClaimData());
    }
}
