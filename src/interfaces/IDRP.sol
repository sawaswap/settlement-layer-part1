// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @title IDRP — Frozen Boundary Interface to the Dispute Resolution Protocol
/// @notice This interface is a forward declaration consistent with the addendum incorporated into
///         SawaSwap Core Protocol v0.11.2 §9 ("DRP Interface — Frozen Boundary"). The DRP itself is
///         out of scope for Part 1; the only Part-1 obligation is that the Settlement Layer is the
///         sole caller of this interface and that the DRP returns a binary outcome within TW3.
/// @dev Concrete signatures, including the input set (PoI / PoR / claim / timing / escrow state /
///      locked stake 1) and the binary outcome encoding, are stubbed for M1 and finalised in M2
///      when the mock harness lands. Selectors declared here are placeholders, subject to revision
///      on the M2 PR introducing the harness.
interface IDRP {
    /// @notice Outcome enumeration returned by `resolve`.
    enum Outcome {
        Settled,
        Reversed
    }

    /// @notice Resolve a disputed transaction. Callable only by the Settlement Layer.
    /// @dev Hard constraints (per addendum §2 and v0.11.2 §9):
    ///      - single invocation per STID;
    ///      - ≤ TW3 from invocation;
    ///      - no escrow mutation, no PoI mutation, no state-machine mutation;
    ///      - pure function from inputs to `Outcome`.
    /// @param stid The Settlement-Layer transaction identifier.
    /// @return outcome Either `Settled` or `Reversed`.
    function resolve(bytes32 stid) external returns (Outcome outcome);
}
