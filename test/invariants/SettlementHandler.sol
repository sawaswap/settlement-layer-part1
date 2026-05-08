// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Settlement} from "../../src/Settlement.sol";
import {Direction, PoIInput, TimeWindows} from "../../src/types/Types.sol";

/// @title SettlementHandler — bounded driver for the Settlement Layer invariant suite (M1)
/// @notice The handler is the only contract the invariant fuzzer is permitted to call. It accepts
///         random inputs from Foundry, bounds them into a meaningful range, calls `commitPoI`, and
///         records the inputs so the invariants can compare stored state against expected state.
contract SettlementHandler is Test {
    Settlement public immutable settlement;

    bytes32[] public stids;
    mapping(bytes32 stid => uint256 amount) public expectedAmount;
    mapping(bytes32 stid => uint64 tw1) public expectedTW1;
    mapping(bytes32 stid => uint64 tw2) public expectedTW2;
    mapping(bytes32 stid => uint64 tw3) public expectedTW3;

    uint256 public commitAttempts;
    uint256 public commitSuccesses;

    constructor(Settlement settlement_) {
        settlement = settlement_;
    }

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
            commitSuccesses++;
        } catch {
            // tolerated under fail_on_revert = false
        }
    }

    function getStidCount() external view returns (uint256) {
        return stids.length;
    }

    function getStidAt(uint256 i) external view returns (bytes32) {
        return stids[i];
    }
}
