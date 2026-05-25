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

/// @title SettlementInvariants — Part 1 invariant suite (M2)
/// @notice Seven properties (P1–P7) exercised by the handler-driven Foundry invariant runner over
///         the full M2 transition surface. The handler registers every M2 entry point
///         (`commitPoI`, `submitPoR`, `pokeTW1`, `submitClaim`, `updateClaim`, `expireTW2`,
///         `invokeDRP`, `expireTW3`) plus a time-advancement action, so the fuzzer explores the
///         whole state machine rather than just the commit surface. The deterministic
///         `test_HandlerWiring_AllBoundedTransitionsCanSucceed` guards against the
///         "handler always reverts" antipattern under `fail_on_revert = false`.
/// @dev Property catalogue with clause anchors lives in `TESTING.md`.
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
        handler = new SettlementHandler(settlement, usdc, drp);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = SettlementHandler.commitPoI_bounded.selector;
        selectors[1] = SettlementHandler.submitPoR_bounded.selector;
        selectors[2] = SettlementHandler.pokeTW1_bounded.selector;
        selectors[3] = SettlementHandler.submitClaim_bounded.selector;
        selectors[4] = SettlementHandler.updateClaim_bounded.selector;
        selectors[5] = SettlementHandler.expireTW2_bounded.selector;
        selectors[6] = SettlementHandler.invokeDRP_bounded.selector;
        selectors[7] = SettlementHandler.expireTW3_bounded.selector;
        selectors[8] = SettlementHandler.warp_bounded.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev P1 — Terminal absorbing. The `terminalMoved` flag and a terminal state
    ///      (`Settled` / `Reversed`) are set together by the finalisation helpers and by nothing
    ///      else; no transition leaves a terminal state. Asserting the biconditional
    ///      `terminalMoved <=> (state is Settled or Reversed)` across every observed transaction
    ///      catches both a terminal transaction re-leaving its state and `terminalMoved` being
    ///      set without the matching terminal transition. v0.11.2 §3 / §C.3.4.
    function invariant_P1_terminalAbsorbing() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            Transaction memory txn = settlement.getTransaction(handler.getStidAt(i));
            bool terminal = txn.state == State.Settled || txn.state == State.Reversed;
            assertEq(terminal, txn.terminalMoved, "terminalMoved must agree with terminal state");
        }
    }

    /// @dev P2 — No transaction without `commitPoI`. Every STID the handler recorded must exist
    ///      on-chain with fully populated, non-zero core fields. Catches any path that could
    ///      register an STID without going through the commit constructor of the record.
    function invariant_P2_noTransactionWithoutCommitPoI() public view {
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

    /// @dev P3 — Escrow conservation. The Settlement contract's USDC balance equals the sum of
    ///      `escrowAmount` over exactly the transactions that have NOT terminal-moved. A
    ///      transaction's escrow is in the contract from `commitPoI` until its terminal transition
    ///      releases it; after `terminalMoved` flips true the escrow has left and the transaction
    ///      drops out of the active sum. v0.11.2 §3 escrow [1] / §C.2.
    function invariant_P3_escrowConservation() public view {
        uint256 n = handler.getStidCount();
        uint256 activeEscrow;
        for (uint256 i = 0; i < n; i++) {
            Transaction memory txn = settlement.getTransaction(handler.getStidAt(i));
            if (!txn.terminalMoved) {
                activeEscrow += txn.escrowAmount;
            }
        }
        assertEq(
            usdc.balanceOf(address(settlement)),
            activeEscrow,
            "contract USDC balance must equal sum of non-terminal escrow"
        );
    }

    /// @dev P4 — Time windows locked at PoI. Even if the admin changes the defaults after a
    ///      commit, an already-committed transaction retains its commit-time TW1 / TW2 / TW3.
    ///      v0.11.2 §C.3.3 / §C.3.7.
    function invariant_P4_timeWindowsLockedAtCommit() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            Transaction memory txn = settlement.getTransaction(stid);
            assertEq(txn.tw1, handler.expectedTW1(stid), "tw1 must be locked at PoI");
            assertEq(txn.tw2, handler.expectedTW2(stid), "tw2 must be locked at PoI");
            assertEq(txn.tw3, handler.expectedTW3(stid), "tw3 must be locked at PoI");
        }
    }

    /// @dev P5 — Single-move (escrow amount immutability). The escrow amount recorded at
    ///      `commitPoI` never changes. Combined with P1 (`terminalMoved` tracks the terminal
    ///      transition) and P3 (terminal escrow is excluded from the contract balance), this gives
    ///      the single-move invariant: escrow leaves the contract exactly once, at the terminal
    ///      transition, in precisely the committed amount. v0.11.2 §3 / §C.3.4.
    function invariant_P5_singleMove_escrowAmountImmutable() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            Transaction memory txn = settlement.getTransaction(stid);
            assertGt(txn.escrowAmount, 0, "escrow amount must be positive");
            assertEq(txn.escrowAmount, handler.expectedAmount(stid), "escrow amount immutable after commit");
        }
    }

    /// @dev P6 — DRP single-invocation consistency. `drpInvoked` is set only as part of the
    ///      `invokeDRP` transition, which moves the state to `EscalationL2_DRP` and then
    ///      atomically to a terminal state. So `drpInvoked == true` implies the state is
    ///      `EscalationL2_DRP`, `Settled`, or `Reversed` — never `PoICommitted` or `EscalationL1`.
    ///      A second `invokeDRP` is blocked by the state guard and the `DRPAlreadyInvoked` guard.
    ///      v0.11.2 §9 / addendum §2.
    function invariant_P6_drpInvokedConsistency() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            Transaction memory txn = settlement.getTransaction(handler.getStidAt(i));
            if (txn.drpInvoked) {
                bool postDRP =
                    txn.state == State.EscalationL2_DRP || txn.state == State.Settled || txn.state == State.Reversed;
                assertTrue(postDRP, "drpInvoked implies state is EscalationL2_DRP or terminal");
            }
        }
    }

    /// @dev P7 — Eligible-claimant immutability. The `eligibleClaimant` recorded at `commitPoI`
    ///      never changes for the life of the transaction. The claimant predicate gates
    ///      `submitPoR` / `submitClaim` / `updateClaim` / `invokeDRP`, so a mutable claimant
    ///      would silently widen the authorised-caller set. v0.11.2 §C.2 / §5–§7.
    function invariant_P7_eligibleClaimantImmutable() public view {
        uint256 n = handler.getStidCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 stid = handler.getStidAt(i);
            Transaction memory txn = settlement.getTransaction(stid);
            assertEq(txn.eligibleClaimant, handler.eligibleClaimantOf(stid), "eligibleClaimant immutable after commit");
        }
    }

    /// @dev Handler-wiring smoke test (not an invariant — a deterministic unit test). Foundry
    ///      reverts handler state to the post-`setUp` snapshot between invariant runs, so a
    ///      post-campaign `afterInvariant` counter assertion can only ever observe a single run
    ///      and is unsuitable as a coverage guard. Instead, this deterministic walk drives each
    ///      handler `*_bounded` entry point through a hand-picked success path and asserts the
    ///      per-function success counter increments. It is the automated guard against the
    ///      "handler always reverts" antipattern: if a handler entry point is mis-wired (wrong
    ///      prank identity, wrong bound range, unregistered selector) this test fails
    ///      deterministically, independent of any fuzz seed. Campaign-wide call distribution is
    ///      separately visible in Foundry's per-selector summary table.
    function test_HandlerWiring_AllBoundedTransitionsCanSucceed() public {
        bytes32 momo = keccak256("smoke");
        address sender = address(0x5E4DE7);

        // ── Lifecycle A: commit → submitPoR (within TW1) → Settled.
        handler.commitPoI_bounded(100e6, 0, address(0xBEEF1), address(0xC1A1), momo, sender);
        handler.submitPoR_bounded(0, bytes("por"));

        // ── Lifecycle B: commit → warp past TW1 → pokeTW1 → submitClaim → updateClaim → invokeDRP.
        handler.commitPoI_bounded(100e6, 0, address(0xBEEF1), address(0xC1A1), momo, sender);
        handler.warp_bounded(2 hours); // past TW1 (30 min)
        handler.pokeTW1_bounded(1, address(0xF00D));
        handler.submitClaim_bounded(1, bytes("claim"));
        handler.updateClaim_bounded(1, bytes("claim-v2"));
        handler.invokeDRP_bounded(1, 0); // outcome seed 0 -> Settled

        // ── Lifecycle C: commit → warp past TW1+TW2 → expireTW2 default-reverse → Reversed.
        handler.commitPoI_bounded(100e6, 0, address(0xBEEF1), address(0xC1A1), momo, sender);
        handler.warp_bounded(13 hours); // past TW1 + TW2 (30 min + 12 h)
        handler.expireTW2_bounded(2, address(0xF00D));

        // ── Lifecycle D: commit → warp past TW1 → pokeTW1 → submitClaim → warp past full
        //                TW1+TW2+TW3 (no invokeDRP) → expireTW3 default-reverse → Reversed.
        //                This is the claim-but-no-DRP-resolution liveness path that the re-guarded
        //                `expireTW3` covers (poker fires from `EscalationL1` with `_claimHash != 0`
        //                after `committedAt + tw1 + tw2 + tw3`).
        handler.commitPoI_bounded(100e6, 0, address(0xBEEF1), address(0xC1A1), momo, sender);
        handler.warp_bounded(1 hours); // past TW1 (30 min) for stid 3
        handler.pokeTW1_bounded(3, address(0xF00D));
        handler.submitClaim_bounded(3, bytes("claim-tw3"));
        handler.warp_bounded(75 hours); // past TW1+TW2+TW3 (30 min + 12 h + 48 h) for stid 3
        handler.expireTW3_bounded(3, address(0xF00D));

        assertGt(handler.commitSuccesses(), 0, "commitPoI wiring");
        assertGt(handler.porSuccesses(), 0, "submitPoR wiring");
        assertGt(handler.pokeTW1Successes(), 0, "pokeTW1 wiring");
        assertGt(handler.claimSuccesses(), 0, "submitClaim wiring");
        assertGt(handler.updateClaimSuccesses(), 0, "updateClaim wiring");
        assertGt(handler.expireTW2Successes(), 0, "expireTW2 wiring");
        assertGt(handler.invokeDRPSuccesses(), 0, "invokeDRP wiring");
        assertGt(handler.expireTW3Successes(), 0, "expireTW3 wiring");

        // Assert the final state of the four-lifecycle walk against every property. Under
        // `fail_on_revert = false`, the fuzz campaign reaches each terminal only probabilistically
        // — a local probe of one P1 campaign (256 runs) saw ~4% of runs hit a TW3-reversal at
        // least once. The properties P1/P3/P5/P6 are therefore observed against a TW3-reversed
        // transaction under fuzzing, but thinly. The asserts below close that gap deterministically:
        // P1–P7 are checked against a single deterministic state that holds all four M2 terminal
        // forms simultaneously (PoR-settled, DRP-resolved, TW2-reversed, TW3-reversed), so each
        // property is observed against every terminal form independent of any fuzz seed.
        assertEq(
            uint8(settlement.getTransaction(handler.getStidAt(0)).state),
            uint8(State.Settled),
            "lifecycle A: PoR-settled"
        );
        assertEq(
            uint8(settlement.getTransaction(handler.getStidAt(1)).state),
            uint8(State.Settled),
            "lifecycle B: DRP-resolved Settled"
        );
        assertEq(
            uint8(settlement.getTransaction(handler.getStidAt(2)).state),
            uint8(State.Reversed),
            "lifecycle C: TW2 default-reverse"
        );
        assertEq(
            uint8(settlement.getTransaction(handler.getStidAt(3)).state),
            uint8(State.Reversed),
            "lifecycle D: TW3 default-reverse"
        );

        invariant_P1_terminalAbsorbing();
        invariant_P2_noTransactionWithoutCommitPoI();
        invariant_P3_escrowConservation();
        invariant_P4_timeWindowsLockedAtCommit();
        invariant_P5_singleMove_escrowAmountImmutable();
        invariant_P6_drpInvokedConsistency();
        invariant_P7_eligibleClaimantImmutable();
    }
}
