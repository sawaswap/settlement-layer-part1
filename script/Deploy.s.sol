// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Settlement} from "../src/Settlement.sol";
import {TimeWindows} from "../src/types/Types.sol";
import {IDRP} from "../src/interfaces/IDRP.sol";
import {MockDRP} from "../test/mocks/MockDRP.sol";

/// @title Deploy — canonical M3 deployment script for the SawaSwap Settlement Layer (Part 1)
/// @notice Deploys `MockDRP` (frozen-interface stub per §C.3.7) and then `Settlement` on the target
///         chain, with the canonical admin wired into the constructor. Targeted at Base Sepolia for
///         M3 testnet handover per §D.2.4; Base Mainnet is out of Part 1 scope per §C.3.5 / §C.3.7.
/// @dev    Per §B.3 of the engagement contract, this script is run by the Client (Francis) from
///         his own wallet. The canonical admin address `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`
///         was pinned by the Client on 2026-05-26 via written confirmation and is enforced below as
///         a hard require so the script cannot deploy with any other admin. The dev variant
///         (`DeployDev.s.sol`) is for our own pre-validation deploys and has no such guard.
/// @dev    Environment variables required:
///         - `USDC_ADDRESS`           — ERC-20 escrow asset on the deployment chain. For Base
///                                      Sepolia, the Circle-issued testnet USDC is
///                                      `0x036CbD53842c5426634e7929541eC2318f3dCF7e`.
///         - `ADMIN_ADDRESS`          — Must equal `0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e`.
///         - `DEFAULT_TW1_SECONDS`    — Initial TW1 default (seconds). Non-zero.
///         - `DEFAULT_TW2_SECONDS`    — Initial TW2 default (seconds). Non-zero.
///         - `DEFAULT_TW3_SECONDS`    — Initial TW3 default (seconds). Non-zero.
/// @dev    The deployer key + RPC URL are supplied by Foundry's standard mechanisms
///         (`--account <keystore>` or `--private-key`, `--rpc-url <name-or-url>`); nothing about
///         the deployer environment is hard-coded into this script.
contract Deploy is Script {
    /// @dev Canonical admin address pinned by the Client on 2026-05-26. Hard-required below so the
    ///      script cannot deploy with any other admin. To change this address, both Parties must
    ///      agree in writing and this constant must be updated explicitly in a tracked commit.
    address internal constant CANONICAL_ADMIN = 0x434F2A01CccAEcFAa884b42e7c72e46D69ecB76e;

    function run() external returns (Settlement settlement, MockDRP drp) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint64 tw1 = uint64(vm.envUint("DEFAULT_TW1_SECONDS"));
        uint64 tw2 = uint64(vm.envUint("DEFAULT_TW2_SECONDS"));
        uint64 tw3 = uint64(vm.envUint("DEFAULT_TW3_SECONDS"));

        require(admin == CANONICAL_ADMIN, "Deploy: ADMIN_ADDRESS must equal canonical admin pinned 2026-05-26");
        require(usdc != address(0), "Deploy: USDC_ADDRESS must be non-zero");

        vm.startBroadcast();
        drp = new MockDRP();
        settlement =
            new Settlement(IERC20(usdc), IDRP(address(drp)), admin, TimeWindows({tw1: tw1, tw2: tw2, tw3: tw3}));
        vm.stopBroadcast();

        console2.log("MockDRP deployed at: ", address(drp));
        console2.log("Settlement deployed at:", address(settlement));
        console2.log("Admin (canonical):", admin);
        console2.log("USDC:", usdc);
        console2.log("TW1 / TW2 / TW3 (seconds):", tw1, tw2, tw3);
    }
}
