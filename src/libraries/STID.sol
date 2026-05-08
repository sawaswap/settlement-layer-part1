// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Direction} from "../types/Types.sol";

/// @title STID — SawaSwap Transaction ID derivation
/// @notice Pure library that derives a 32-byte transaction identifier from PoI inputs.
/// @dev Hash form rather than a counter so STIDs are content-addressable and collision-resistant
///      across parallel originators. The originator nonce is supplied by the caller and must be
///      monotonically incremented per originator on every successful PoI commitment.
library STID {
    /// @param originator    `msg.sender` of `commitPoI` — escrow originator.
    /// @param beneficiary   Settlement-time recipient if the transaction reaches `Settled`.
    /// @param direction     CMM or MMC.
    /// @param escrowAmount  Locked USDC amount, in token base units.
    /// @param momoLegHash   On-chain commitment to the off-chain MoMo leg metadata.
    /// @param chainId       `block.chainid` — survives chain replay across forks.
    /// @param nonce         Caller-supplied per-originator nonce.
    /// @return stid         The derived 32-byte STID.
    function derive(
        address originator,
        address beneficiary,
        Direction direction,
        uint256 escrowAmount,
        bytes32 momoLegHash,
        uint256 chainId,
        uint256 nonce
    ) internal pure returns (bytes32 stid) {
        stid = keccak256(abi.encode(originator, beneficiary, direction, escrowAmount, momoLegHash, chainId, nonce));
    }
}
