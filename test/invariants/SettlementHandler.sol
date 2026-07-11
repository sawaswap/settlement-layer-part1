// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Settlement} from "../../src/Settlement.sol";
import {State, Direction, Transaction, PoIInput, TimeWindows} from "../../src/types/Types.sol";
import {IDRP} from "../../src/interfaces/IDRP.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDRP} from "../mocks/MockDRP.sol";

/// @title SettlementHandler — bounded driver for the Settlement Layer invariant suite (M2)
/// @notice The handler is the only contract the invariant fuzzer is permitted to call. Each
///         `*_bounded` entry point accepts random inputs from Foundry, bounds them into a
///         meaningful range, satisfies the relevant preconditions where practical (funding,
///         approvals, caller identity, time advancement), and drives the corresponding Settlement
///         Layer transition inside a try/catch so a reverted attempt is tolerated under
///         `fail_on_revert = false`.
/// @dev Every entry point increments an attempt counter and, on success, a success counter.
///      Foundry reverts handler storage to the post-`setUp` snapshot between invariant runs, so
///      these counters cannot be aggregated across a campaign; they are instead asserted by the
///      deterministic `test_HandlerWiring_AllBoundedTransitionsCanSucceed` smoke test, which
///      drives each entry point through a hand-picked success path. That test is the guard
///      against the "handler always reverts" antipattern where the fuzzer registers a selector
///      but every transition silently reverts and the invariants pass vacuously.
contract SettlementHandler is Test {
    Settlement public immutable settlement;
    MockERC20 public immutable usdc;
    MockDRP public immutable drp;

    /// @dev Every STID returned by a successful `commitPoI`.
    bytes32[] public stids;

    mapping(bytes32 stid => uint256 amount) public expectedAmount;
    mapping(bytes32 stid => uint64 tw1) public expectedTW1;
    mapping(bytes32 stid => uint64 tw2) public expectedTW2;
    mapping(bytes32 stid => uint64 tw3) public expectedTW3;
    mapping(bytes32 stid => address claimant) public eligibleClaimantOf;
    mapping(bytes32 stid => address originator) public originatorOf;

    // ─── Per-function attempt / success counters ─────────────────────────────────────────────────

    uint256 public commitAttempts;
    uint256 public commitSuccesses;
    uint256 public porAttempts;
    uint256 public porSuccesses;
    uint256 public pokeTW1Attempts;
    uint256 public pokeTW1Successes;
    uint256 public claimAttempts;
    uint256 public claimSuccesses;
    uint256 public updateClaimAttempts;
    uint256 public updateClaimSuccesses;
    uint256 public expireTW2Attempts;
    uint256 public expireTW2Successes;
    uint256 public invokeDRPAttempts;
    uint256 public invokeDRPSuccesses;
    uint256 public expireTW3Attempts;
    uint256 public expireTW3Successes;

    constructor(Settlement settlement_, MockERC20 usdc_, MockDRP drp_) {
        settlement = settlement_;
        usdc = usdc_;
        drp = drp_;
    }

    // ─── commitPoI ───────────────────────────────────────────────────────────────────────────────

    function commitPoI_bounded(
        uint256 amount,
        uint8 dirSeed,
        address bene,
        address claimant,
        bytes32 momo,
        address sender
    ) external {
        commitAttempts++;

        amount = bound(amount, 1, 1e18);
        Direction dir = Direction(uint8(bound(uint256(dirSeed), 0, 1)));
        if (bene == address(0)) bene = address(0xBEEF);
        if (claimant == address(0)) claimant = address(0xC1A1);
        if (sender == address(0)) sender = address(0xCAFE);
        // The fuzzer must not act AS the Settlement or escrow-token contract: `msg.sender ==
        // address(this)` is unreachable for an external entry point in production (no code path
        // self-calls `commitPoI`), and an originator of `address(settlement)` would make the
        // reverse-path `safeTransfer` a same-address no-op, a model artifact — not a reachable
        // state. Remap such senders to a realistic EOA so the escrow-conservation invariant (P3)
        // is exercised over reachable states. The contract itself guards the reachable
        // reflexive surface — `beneficiary` / `eligibleClaimant` (KRAIT-001) — which the fuzzer
        // still exercises freely (those commits revert and are caught below).
        if (sender == address(settlement) || sender == address(usdc)) sender = address(0xCAFE);

        // Fund and approve the random sender so the escrow pull succeeds. Done unconditionally —
        // even if the commit reverts on another precondition, the spare allowance is harmless.
        usdc.mint(sender, amount);
        vm.prank(sender);
        usdc.approve(address(settlement), amount);

        TimeWindows memory tw = settlement.getDefaultTimeWindows();

        PoIInput memory input = PoIInput({
            beneficiary: bene, eligibleClaimant: claimant, direction: dir, escrowAmount: amount, momoLegHash: momo
        });

        vm.prank(sender);
        try settlement.commitPoI(input) returns (bytes32 stid) {
            stids.push(stid);
            expectedAmount[stid] = amount;
            expectedTW1[stid] = tw.tw1;
            expectedTW2[stid] = tw.tw2;
            expectedTW3[stid] = tw.tw3;
            eligibleClaimantOf[stid] = claimant;
            originatorOf[stid] = sender;
            commitSuccesses++;
        } catch {
            // tolerated under fail_on_revert = false
        }
    }

    // ─── submitPoR ───────────────────────────────────────────────────────────────────────────────

    function submitPoR_bounded(uint256 stidSeed, bytes calldata porData) external {
        if (stids.length == 0) return;
        porAttempts++;

        bytes32 stid = _pickStid(stidSeed);
        bytes memory data = porData.length == 0 ? bytes("por-fuzz") : porData;

        vm.prank(eligibleClaimantOf[stid]);
        try settlement.submitPoR(stid, data) {
            porSuccesses++;
        } catch {}
    }

    // ─── pokeTW1 ─────────────────────────────────────────────────────────────────────────────────

    function pokeTW1_bounded(uint256 stidSeed, address caller) external {
        if (stids.length == 0) return;
        pokeTW1Attempts++;

        bytes32 stid = _pickStid(stidSeed);
        if (caller == address(0)) caller = address(0xF00D);

        vm.prank(caller);
        try settlement.pokeTW1(stid) {
            pokeTW1Successes++;
        } catch {}
    }

    // ─── submitClaim ─────────────────────────────────────────────────────────────────────────────

    function submitClaim_bounded(uint256 stidSeed, bytes calldata claimData) external {
        if (stids.length == 0) return;
        claimAttempts++;

        bytes32 stid = _pickStid(stidSeed);
        bytes memory data = claimData.length == 0 ? bytes("claim-fuzz") : claimData;

        vm.prank(eligibleClaimantOf[stid]);
        try settlement.submitClaim(stid, data) {
            claimSuccesses++;
        } catch {}
    }

    // ─── updateClaim ─────────────────────────────────────────────────────────────────────────────

    function updateClaim_bounded(uint256 stidSeed, bytes calldata claimData) external {
        if (stids.length == 0) return;
        updateClaimAttempts++;

        bytes32 stid = _pickStid(stidSeed);
        bytes memory data = claimData.length == 0 ? bytes("claim-fuzz-v2") : claimData;

        vm.prank(eligibleClaimantOf[stid]);
        try settlement.updateClaim(stid, data) {
            updateClaimSuccesses++;
        } catch {}
    }

    // ─── expireTW2 ───────────────────────────────────────────────────────────────────────────────

    function expireTW2_bounded(uint256 stidSeed, address caller) external {
        if (stids.length == 0) return;
        expireTW2Attempts++;

        bytes32 stid = _pickStid(stidSeed);
        if (caller == address(0)) caller = address(0xF00D);

        vm.prank(caller);
        try settlement.expireTW2(stid) {
            expireTW2Successes++;
        } catch {}
    }

    // ─── invokeDRP ───────────────────────────────────────────────────────────────────────────────

    function invokeDRP_bounded(uint256 stidSeed, uint8 outcomeSeed) external {
        if (stids.length == 0) return;
        invokeDRPAttempts++;

        bytes32 stid = _pickStid(stidSeed);
        IDRP.Outcome outcome = IDRP.Outcome(uint8(bound(uint256(outcomeSeed), 0, 1)));
        drp.setOutcome(stid, outcome);

        vm.prank(eligibleClaimantOf[stid]);
        try settlement.invokeDRP(stid) {
            invokeDRPSuccesses++;
        } catch {}
    }

    // ─── expireTW3 ───────────────────────────────────────────────────────────────────────────────

    function expireTW3_bounded(uint256 stidSeed, address caller) external {
        if (stids.length == 0) return;
        expireTW3Attempts++;

        bytes32 stid = _pickStid(stidSeed);
        if (caller == address(0)) caller = address(0xF00D);

        vm.prank(caller);
        try settlement.expireTW3(stid) {
            expireTW3Successes++;
        } catch {}
    }

    // ─── time advancement ────────────────────────────────────────────────────────────────────────

    /// @dev Advances `block.timestamp` so that time-window-gated transitions become reachable for
    ///      the fuzzer. Bounded to a wide range covering sub-TW1 nudges through full-TW3 expiry.
    function warp_bounded(uint256 secs) external {
        secs = bound(secs, 1, 100 hours);
        vm.warp(block.timestamp + secs);
    }

    // ─── views ───────────────────────────────────────────────────────────────────────────────────

    function getStidCount() external view returns (uint256) {
        return stids.length;
    }

    function getStidAt(uint256 i) external view returns (bytes32) {
        return stids[i];
    }

    function _pickStid(uint256 seed) internal view returns (bytes32) {
        return stids[seed % stids.length];
    }
}
