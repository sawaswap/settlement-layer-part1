// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Settlement} from "../src/Settlement.sol";
import {TimeWindows} from "../src/types/Types.sol";
import {IDRP} from "../src/interfaces/IDRP.sol";
import {MockDRP} from "../test/mocks/MockDRP.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title DeployDev — dev-only pre-validation deploy script for the SawaSwap Settlement Layer
/// @notice **NOT FOR CANONICAL DEPLOYMENTS.** This script is the dev-side counterpart to
///         `Deploy.s.sol`, used by the Developer to throw-away-deploy on Base Sepolia for
///         pre-validation of the canonical script + verification check sequencing before the
///         Client runs the canonical deploy from his own wallet. It has no canonical-admin
///         equality guard — the admin is whichever address `ADMIN_ADDRESS` resolves to (defaults
///         to the broadcaster).
/// @dev    Two convenience differences vs `Deploy.s.sol`:
///         1. `USDC_ADDRESS` is optional. If unset, deploys a fresh `MockERC20` (6 decimals, "USDC"
///            symbol) inline and uses that. Lets verification flows mint freely without a faucet.
///         2. `ADMIN_ADDRESS` is optional. If unset, falls back to `tx.origin` during broadcast,
///            which equals the deployer EOA used by `forge script`.
///         Time windows use M1-RUNBOOK demo defaults (600 / 1800 / 3600 seconds) if env unset, for
///         fast iteration on testnet.
/// @dev    Instances deployed by this script must NEVER be treated as canonical. They are
///         throwaway by definition; do not register their addresses anywhere durable.
contract DeployDev is Script {
    function run() external returns (Settlement settlement, MockDRP drp, address usdc) {
        // Resolve admin: env override or broadcaster (tx.origin during broadcast == the
        // --account/--private-key EOA).
        address admin = vm.envOr("ADMIN_ADDRESS", address(0));
        if (admin == address(0)) admin = tx.origin;

        // Resolve USDC: env override or fresh MockERC20.
        usdc = vm.envOr("USDC_ADDRESS", address(0));

        uint64 tw1 = uint64(vm.envOr("DEFAULT_TW1_SECONDS", uint256(600)));
        uint64 tw2 = uint64(vm.envOr("DEFAULT_TW2_SECONDS", uint256(1800)));
        uint64 tw3 = uint64(vm.envOr("DEFAULT_TW3_SECONDS", uint256(3600)));

        vm.startBroadcast();
        if (usdc == address(0)) {
            MockERC20 mockUsdc = new MockERC20("USD Coin (dev)", "USDC", 6);
            usdc = address(mockUsdc);
        }
        drp = new MockDRP();
        settlement =
            new Settlement(IERC20(usdc), IDRP(address(drp)), admin, TimeWindows({tw1: tw1, tw2: tw2, tw3: tw3}));
        vm.stopBroadcast();

        console2.log("[DEV] MockDRP deployed at:", address(drp));
        console2.log("[DEV] USDC token:", usdc);
        console2.log("[DEV] Settlement deployed at:", address(settlement));
        console2.log("[DEV] Admin (dev only, NOT canonical):", admin);
        console2.log("[DEV] TW1 / TW2 / TW3 (seconds):", tw1, tw2, tw3);
    }
}
