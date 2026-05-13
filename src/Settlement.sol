// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {State, Direction, Transaction, TimeWindows, PoIInput} from "./types/Types.sol";
import {STID} from "./libraries/STID.sol";

/// @title Settlement — SawaSwap Settlement Layer (Part 1)
/// @notice Implements the Part 1 state machine of the SawaSwap protocol (Core Protocol v0.11.2):
///         PoI commitment, escrow accounting, time-window storage, claim admissibility, DRP boundary.
/// @dev M1 delivered the on-chain skeleton: state enum, transaction storage, `commitPoI`, getters,
///      and admin-restricted time-window configuration. M2 progressively replaces the M2 stubs:
///      PR #3 added escrow lock on `commitPoI`; PR #4 adds `submitPoR` and the Settled finality
///      path; PR #5–#7 will add TW1/TW2/TW3 expiry, claim handling, and the DRP boundary. External
///      `settle` / `reverse` recovery hatches remain stubbed pending bilateral confirmation of
///      their intended semantics. Production deployment guards (Section E of the Agreement) are
///      gated to a separate phase beyond Part 1.
contract Settlement is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role authorised to operate the Parameter Configuration Carve-Out under §C.3.7.
    /// @dev Held by the Client multisignature wallet on production-bound deployments.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice ERC-20 token used as the escrow asset (USDC on the deployment chain).
    IERC20 public immutable USDC;

    /// @dev Default time-window configuration; overridable per rail-pair via {setRailPairProfile}.
    TimeWindows private _defaultTW;

    /// @dev TW1 override per directional rail-pair profile (per §C.3.3).
    mapping(bytes32 railPairId => uint64 tw1) private _railPairTW1;

    /// @dev Settlement-layer transaction store. Keyed by deterministic STID (see {STID.derive}).
    mapping(bytes32 stid => Transaction txn) private _txs;

    /// @dev Existence sentinel — distinguishes "no record" from "record with default-zero fields".
    mapping(bytes32 stid => bool exists) private _exists;

    /// @dev Per-originator nonce for STID derivation; ensures uniqueness across repeat originators.
    mapping(address originator => uint256 nonce) private _nonce;

    /// @dev Hash of the PoR payload submitted for a given STID (zero if no PoR has been submitted).
    ///      Stored as a secondary mapping rather than a `Transaction` field to preserve the M1 ABI
    ///      of the struct. The raw payload is not retained on-chain — indexers reconstruct it from
    ///      the originating transaction's calldata.
    mapping(bytes32 stid => bytes32 porHash) private _porHash;

    // ─── M1 events ───────────────────────────────────────────────────────────────────────────────

    /// @notice Emitted on a successful `commitPoI`.
    event PoICommitted(
        bytes32 indexed stid,
        address indexed originator,
        address indexed beneficiary,
        Direction direction,
        uint256 escrowAmount,
        uint64 tw1,
        uint64 tw2,
        uint64 tw3
    );

    /// @notice Emitted on every state transition.
    event StateChanged(bytes32 indexed stid, State previous, State current);

    /// @notice Emitted when an admin updates the default time-window configuration.
    event TimeWindowsConfigured(uint64 tw1, uint64 tw2, uint64 tw3, address indexed by);

    /// @notice Emitted when an admin sets or updates the TW1 profile for a rail-pair identifier.
    event RailPairProfileSet(bytes32 indexed railPairId, uint64 tw1, address indexed by);

    // ─── M2 events (declared in M1 to freeze ABI selectors; not emitted yet) ─────────────────────

    event PoRSubmitted(bytes32 indexed stid);
    event ClaimSubmitted(bytes32 indexed stid, address indexed claimant);
    event ClaimUpdated(bytes32 indexed stid);
    event DRPInvoked(bytes32 indexed stid);
    event Settled(bytes32 indexed stid, address indexed beneficiary, uint256 amount);
    event Reversed(bytes32 indexed stid, address indexed originator, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    error ZeroAmount();
    error DuplicateSTID();
    error TransactionNotFound();
    error NotImplementedM1();
    error InvalidTimeWindow();
    error InvalidAddress();

    /// @notice Thrown when an operation is attempted from an incompatible state.
    /// @param expected The state required by the operation's precondition.
    /// @param actual   The state recorded for the targeted transaction.
    error InvalidState(uint8 expected, uint8 actual);

    /// @notice Thrown when the relevant time window for an operation has already elapsed.
    error WindowExpired();

    /// @notice Thrown when `msg.sender` is not the address permitted to submit a PoR for this STID.
    /// @dev The PoR submitter is the off-chain receiver, recorded on-chain as `eligibleClaimant`
    ///      at PoI commitment (v0.11.2 §C.2 and §5–§7).
    error NotPoRSubmitter();

    /// @notice Thrown when PoR payload bytes are empty or otherwise structurally invalid.
    /// @dev M2 enforces only the non-empty precondition. Semantic validation of the payload is
    ///      out of Part-1 scope and deferred to the off-chain pipeline / DRP layer.
    error InvalidPoRData();

    /// @notice Thrown when a finalisation helper is invoked on a transaction whose escrow has
    ///         already been moved (single-move invariant).
    error AlreadyFinalized();

    // ─── Construction ────────────────────────────────────────────────────────────────────────────

    /// @param usdc                 ERC-20 token contract used for escrow (USDC on the target chain).
    /// @param admin                Address that holds the protocol's `ADMIN_ROLE` and `DEFAULT_ADMIN_ROLE`.
    ///                             On production deployments this is the Client's Safe multisig.
    /// @param defaultTimeWindows   Initial default TW1 / TW2 / TW3 (in seconds). All non-zero.
    constructor(IERC20 usdc, address admin, TimeWindows memory defaultTimeWindows) {
        if (address(usdc) == address(0)) revert InvalidAddress();
        if (admin == address(0)) revert InvalidAddress();
        if (defaultTimeWindows.tw1 == 0 || defaultTimeWindows.tw2 == 0 || defaultTimeWindows.tw3 == 0) {
            revert InvalidTimeWindow();
        }

        USDC = usdc;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _defaultTW = defaultTimeWindows;
    }

    // ─── M1 implemented surface ──────────────────────────────────────────────────────────────────

    /// @notice Commits a Proof of Intent (PoI), pulls escrow from the originator, and creates a
    ///         settlement-layer transaction record.
    /// @dev Records the locked-at-PoI time windows on the transaction so subsequent admin updates
    ///      to the defaults do not retroactively change windows for already-committed transactions.
    ///      Escrow is pulled via `USDC.safeTransferFrom`; the originator must have approved this
    ///      contract for at least `input.escrowAmount` prior to the call. The transfer is the last
    ///      action in the function (Checks-Effects-Interactions) and reverts the entire call on
    ///      failure, leaving no half-committed state behind.
    /// @param input PoI input bundle (beneficiary, eligible claimant, direction, amount, MoMo hash).
    /// @return stid The derived 32-byte SawaSwap Transaction ID.
    function commitPoI(PoIInput calldata input) external nonReentrant returns (bytes32 stid) {
        if (input.escrowAmount == 0) revert ZeroAmount();
        if (input.beneficiary == address(0) || input.eligibleClaimant == address(0)) {
            revert InvalidAddress();
        }

        uint256 nonce = _nonce[msg.sender]++;
        stid = STID.derive(
            msg.sender, input.beneficiary, input.direction, input.escrowAmount, input.momoLegHash, block.chainid, nonce
        );

        if (_exists[stid]) revert DuplicateSTID();

        TimeWindows memory tw = _defaultTW;

        _txs[stid] = Transaction({
            stid: stid,
            originator: msg.sender,
            beneficiary: input.beneficiary,
            eligibleClaimant: input.eligibleClaimant,
            direction: input.direction,
            escrowAmount: input.escrowAmount,
            momoLegHash: input.momoLegHash,
            tw1: tw.tw1,
            tw2: tw.tw2,
            tw3: tw.tw3,
            committedAt: uint64(block.timestamp),
            state: State.PoICommitted,
            drpInvoked: false,
            terminalMoved: false
        });
        _exists[stid] = true;

        emit PoICommitted(
            stid, msg.sender, input.beneficiary, input.direction, input.escrowAmount, tw.tw1, tw.tw2, tw.tw3
        );

        USDC.safeTransferFrom(msg.sender, address(this), input.escrowAmount);
    }

    /// @notice Returns the stored transaction record for a given STID.
    /// @dev Reverts `TransactionNotFound` if the STID has never been committed.
    function getTransaction(bytes32 stid) external view returns (Transaction memory) {
        if (!_exists[stid]) revert TransactionNotFound();
        return _txs[stid];
    }

    /// @notice Returns true iff the given STID corresponds to a committed transaction.
    function transactionExists(bytes32 stid) external view returns (bool) {
        return _exists[stid];
    }

    /// @notice Returns the current default time-window configuration.
    function getDefaultTimeWindows() external view returns (TimeWindows memory) {
        return _defaultTW;
    }

    /// @notice Returns the TW1 override registered for a rail-pair identifier (zero if none).
    function getRailPairTW1(bytes32 railPairId) external view returns (uint64) {
        return _railPairTW1[railPairId];
    }

    /// @notice Returns the next STID-derivation nonce for a given originator.
    function getNonce(address originator) external view returns (uint256) {
        return _nonce[originator];
    }

    /// @notice Returns the hash of the PoR payload submitted for a given STID, or `bytes32(0)` if
    ///         no PoR has been submitted.
    function getPoRHash(bytes32 stid) external view returns (bytes32) {
        return _porHash[stid];
    }

    // ─── Parameter Configuration Carve-Out (§C.3.7) ──────────────────────────────────────────────

    /// @notice Updates the default TW1 / TW2 / TW3 used for new commitments.
    /// @dev Existing transactions retain their commit-time windows; only future commitments use the
    ///      new defaults. Restricted to `ADMIN_ROLE` per §C.3.7 Parameter Configuration Carve-Out.
    function setDefaultTimeWindows(uint64 tw1, uint64 tw2, uint64 tw3) external onlyRole(ADMIN_ROLE) {
        if (tw1 == 0 || tw2 == 0 || tw3 == 0) revert InvalidTimeWindow();
        _defaultTW = TimeWindows({tw1: tw1, tw2: tw2, tw3: tw3});
        emit TimeWindowsConfigured(tw1, tw2, tw3, msg.sender);
    }

    /// @notice Sets or updates the TW1 override for a rail-pair identifier.
    /// @dev Restricted to `ADMIN_ROLE` per §C.3.7. Rail-pair selection is consumed by `commitPoI` in M2.
    function setRailPairProfile(bytes32 railPairId, uint64 tw1) external onlyRole(ADMIN_ROLE) {
        if (tw1 == 0) revert InvalidTimeWindow();
        _railPairTW1[railPairId] = tw1;
        emit RailPairProfileSet(railPairId, tw1, msg.sender);
    }

    // ─── M2 implemented surface ──────────────────────────────────────────────────────────────────

    /// @notice Submit a Proof of Receipt (PoR) for an in-flight transaction, settling it.
    /// @dev Implements the happy path of v0.11.2 §3 / §5–§7: a valid PoR submitted within TW1
    ///      drives the transaction from `PoICommitted` to `Settled` atomically, releasing escrow
    ///      to the on-chain beneficiary. M2 validates only that the payload is non-empty; semantic
    ///      verification of the payload is deferred to the off-chain pipeline / DRP layer and is
    ///      out of Part-1 scope. The submitter must be the `eligibleClaimant` recorded at PoI
    ///      commitment, which is the off-chain receiver (CMM → User C, MMC → Agent B per §C.2);
    ///      this is the interpretation derived from §5–§7 and is documented as a PR-level
    ///      assumption ready to be revisited if the Client confirms a different reading.
    /// @param stid    Transaction identifier returned by `commitPoI`.
    /// @param porData PoR payload bytes; only `keccak256(porData)` is retained on-chain.
    function submitPoR(bytes32 stid, bytes calldata porData) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();
        if (porData.length == 0) revert InvalidPoRData();

        Transaction storage txn = _txs[stid];
        if (txn.state != State.PoICommitted) {
            revert InvalidState(uint8(State.PoICommitted), uint8(txn.state));
        }
        // Time-window enforcement against `block.timestamp`. Validator-side manipulation is bounded
        // to a few seconds on Base and is dwarfed by TW1 / TW2 / TW3 (minutes-to-hours scale), so
        // direct comparison is sound here.
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > uint256(txn.committedAt) + uint256(txn.tw1)) revert WindowExpired();
        if (msg.sender != txn.eligibleClaimant) revert NotPoRSubmitter();

        _porHash[stid] = keccak256(porData);
        emit PoRSubmitted(stid);

        _finalizeSettled(stid);
    }

    // ─── M2 stubs ────────────────────────────────────────────────────────────────────────────────

    /// @notice [M2] Submit a claim against a transaction. Reverts in M1.
    function submitClaim(bytes32, bytes calldata) external pure {
        revert NotImplementedM1();
    }

    /// @notice [M2] Update an in-flight claim before the TW2 window closes. Reverts in M1.
    function updateClaim(bytes32, bytes calldata) external pure {
        revert NotImplementedM1();
    }

    /// @notice [M2] Invoke the Dispute Resolution Protocol. Reverts in M1.
    function invokeDRP(bytes32) external pure {
        revert NotImplementedM1();
    }

    /// @notice [M2] Settle an in-flight transaction (release escrow to beneficiary). Reverts in M1.
    function settle(bytes32) external pure {
        revert NotImplementedM1();
    }

    /// @notice [M2] Reverse an in-flight transaction (return escrow to originator). Reverts in M1.
    function reverse(bytes32) external pure {
        revert NotImplementedM1();
    }

    // ─── Internal finalisation helpers ───────────────────────────────────────────────────────────

    /// @dev Drives a transaction to the `Settled` terminal state and releases escrow to the
    ///      beneficiary. Strict Checks-Effects-Interactions: state mutation and `terminalMoved`
    ///      flag are set before the external `safeTransfer`, and the single-move invariant is
    ///      enforced by the `AlreadyFinalized` guard at entry. Callers must hold `nonReentrant`
    ///      at the external entry point.
    function _finalizeSettled(bytes32 stid) internal {
        Transaction storage txn = _txs[stid];
        if (txn.terminalMoved) revert AlreadyFinalized();

        State previous = txn.state;
        txn.state = State.Settled;
        txn.terminalMoved = true;

        emit StateChanged(stid, previous, State.Settled);
        emit Settled(stid, txn.beneficiary, txn.escrowAmount);

        USDC.safeTransfer(txn.beneficiary, txn.escrowAmount);
    }
}
