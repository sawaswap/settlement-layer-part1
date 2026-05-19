// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Settlement} from "../src/Settlement.sol";
import {TimeWindows} from "../src/types/Types.sol";
import {IDRP} from "../src/interfaces/IDRP.sol";

/// @title Deploy — Settlement Layer (Part 1) deployment script
/// @notice Deploys the M2 contract with the supplied USDC and DRP addresses, admin multisig, and
///         default time windows. Targeted at Base Sepolia for M3 testnet handover; Base Mainnet is
///         out of Part 1 scope per Agreement §C.3.5 and §C.3.7.
/// @dev Reads from environment variables:
///      - USDC_ADDRESS              — ERC-20 escrow asset (USDC on the deployment chain).
///      - DRP_ADDRESS               — frozen DRP boundary contract (v0.11.2 §9). For M2 demos this
///                                    is a separately-deployed `MockDRP`; for production the
///                                    canonical DRP address is supplied here.
///      - ADMIN_MULTISIG_ADDRESS    — Client-controlled Safe multisig (`ADMIN_ROLE` holder).
///      - DEFAULT_TW1_SECONDS       — initial TW1 default (e.g., 600 = 10 minutes for testnet).
///      - DEFAULT_TW2_SECONDS       — initial TW2 default (≤ 36 hours per protocol).
///      - DEFAULT_TW3_SECONDS       — initial TW3 default (≤ 72 hours per protocol).
contract Deploy is Script {
    function run() external returns (Settlement settlement) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address drp = vm.envAddress("DRP_ADDRESS");
        address admin = vm.envAddress("ADMIN_MULTISIG_ADDRESS");
        uint64 tw1 = uint64(vm.envUint("DEFAULT_TW1_SECONDS"));
        uint64 tw2 = uint64(vm.envUint("DEFAULT_TW2_SECONDS"));
        uint64 tw3 = uint64(vm.envUint("DEFAULT_TW3_SECONDS"));

        vm.startBroadcast();
        settlement = new Settlement(IERC20(usdc), IDRP(drp), admin, TimeWindows({tw1: tw1, tw2: tw2, tw3: tw3}));
        vm.stopBroadcast();
    }
}
