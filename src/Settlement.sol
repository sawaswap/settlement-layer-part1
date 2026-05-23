// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {State, Direction, Transaction, TimeWindows, PoIInput} from "./types/Types.sol";
import {STID} from "./libraries/STID.sol";
import {IDRP} from "./interfaces/IDRP.sol";

/// @title Settlement — SawaSwap Settlement Layer (Part 1)
/// @notice Implements the Part 1 state machine of the SawaSwap protocol (Core Protocol v0.11.2):
///         PoI commitment, escrow accounting, time-window storage, claim admissibility, DRP boundary.
/// @dev M1 delivered the on-chain skeleton: state enum, transaction storage, `commitPoI`, getters,
///      and admin-restricted time-window configuration. M2 progressively replaces the M2 stubs:
///      PR #3 added escrow lock on `commitPoI`; PR #4 added `submitPoR` and the Settled finality
///      path; PR #5 added TW1 expiry escalation via `pokeTW1`; PR #6 added claim handling
///      (`submitClaim` / `updateClaim`) and TW2 default-reverse via `expireTW2`; PR #7 adds the
///      DRP boundary (`invokeDRP`) and TW3 default-reverse (`expireTW3`). The external `settle` /
///      `reverse` recovery hatches are retained as M1 stubs reverting `NotImplementedM1()` per the
///      15 May ratified decision to drop them as unreachable under SafeERC20 atomic-revert
///      semantics. Production deployment guards (Section E of the Agreement) are gated to a
///      separate phase beyond Part 1.
contract Settlement is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role authorised to operate the Parameter Configuration Carve-Out under §C.3.7.
    /// @dev Held by the Client multisignature wallet on production-bound deployments.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice ERC-20 token used as the escrow asset (USDC on the deployment chain).
    IERC20 public immutable USDC;

    /// @notice Frozen DRP boundary contract (v0.11.2 §9, addendum §2). The Settlement Layer is the
    ///         sole permitted caller of `DRP.resolve(stid)`; the DRP itself is out of Part-1 scope
    ///         and is wired in via a mock harness for M2 testing.
    /// @dev Immutable from construction. The mock is parameterised at deploy time; the production
    ///      address is supplied when the canonical instance deploys in M3.
    IDRP public immutable DRP;

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

    /// @dev Hash of the most recently submitted (or updated) claim payload for a given STID (zero
    ///      if no claim has been submitted). As with `_porHash`, the raw payload lives off-chain
    ///      and indexers reconstruct it from calldata. The mapping is updated in place by
    ///      `updateClaim` so only the latest claim version is on-chain — earlier versions are
    ///      reachable via the historical `ClaimSubmitted` / `ClaimUpdated` event sequence.
    mapping(bytes32 stid => bytes32 claimHash) private _claimHash;

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

    /// @notice Thrown when an escalation poker (pokeTW1 / expireTW2 / expireTW3) is invoked
    ///         before the relevant window has elapsed.
    error EscalationNotDue();

    /// @notice Thrown when `msg.sender` is not the address permitted to submit or update a claim
    ///         for this STID.
    /// @dev The eligible claimant is recorded at PoI commitment as `Transaction.eligibleClaimant`
    ///      and is the off-chain receiver (CMM → User C, MMC → Agent B per v0.11.2 §C.2 / §5–§7).
    error NotEligibleClaimant();

    /// @notice Thrown when the claim payload bytes are empty or otherwise structurally invalid.
    /// @dev M2 enforces only the non-empty precondition. Semantic validation of the payload is
    ///      out of Part-1 scope and deferred to the off-chain pipeline / DRP layer.
    error InvalidClaimData();

    /// @notice Thrown when `submitClaim` is invoked on a transaction that already has a claim on
    ///         record. The eligible claimant should call `updateClaim` instead while the TW2
    ///         window is still open.
    error ClaimAlreadyExists();

    /// @notice Thrown when `updateClaim` is invoked on a transaction that does not yet have a
    ///         claim on record. `submitClaim` must be called first.
    error NoClaimToUpdate();

    /// @notice Thrown when `expireTW2` is invoked on a transaction that already has a claim on
    ///         record. The default-reverse path is reserved for transactions where the eligible
    ///         claimant chose not to file a claim within TW2; once a claim exists the path forward
    ///         is the DRP boundary (`invokeDRP`, PR #7), not the default-reverse poker.
    error ClaimPending();

    /// @notice Thrown when `invokeDRP` is called on a transaction that has no claim on record.
    /// @dev `submitClaim` must be called first; without a claim the DRP has nothing to resolve.
    error NoClaim();

    /// @notice Thrown when `invokeDRP` is called on a transaction whose DRP boundary has already
    ///         been crossed. Enforces the single-invocation invariant per addendum §2 / v0.11.2 §9.
    error DRPAlreadyInvoked();

    // ─── Construction ────────────────────────────────────────────────────────────────────────────

    /// @param usdc                 ERC-20 token contract used for escrow (USDC on the target chain).
    /// @param drp                  Frozen DRP boundary contract per v0.11.2 §9 (addendum §2). M2
    ///                             wires the configurable `MockDRP` harness; M3 / production
    ///                             deployments supply the canonical DRP address.
    /// @param admin                Address that holds the protocol's `ADMIN_ROLE` and `DEFAULT_ADMIN_ROLE`.
    ///                             On production deployments this is the Client's Safe multisig.
    /// @param defaultTimeWindows   Initial default TW1 / TW2 / TW3 (in seconds). All non-zero.
    /// @dev Constructor signature is intentionally widened in PR #7 to accept the DRP address.
    ///      The M1 demo deployment (Base Sepolia, 2026-05-11) was an ad-hoc smoke test and is not
    ///      considered the canonical instance; the M3 deploy under the contract's Section E path
    ///      uses this widened signature directly.
    constructor(IERC20 usdc, IDRP drp, address admin, TimeWindows memory defaultTimeWindows) {
        if (address(usdc) == address(0)) revert InvalidAddress();
        if (address(drp) == address(0)) revert InvalidAddress();
        if (admin == address(0)) revert InvalidAddress();
        if (defaultTimeWindows.tw1 == 0 || defaultTimeWindows.tw2 == 0 || defaultTimeWindows.tw3 == 0) {
            revert InvalidTimeWindow();
        }

        USDC = usdc;
        DRP = drp;
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
    /// @dev Transitions the transaction into v0.11.2 §3 escrow [1] — the persisted lifecycle marker
    ///      indicating escrow is held in Settlement Layer custody. Escrow remains at [1] until
    ///      terminal finality moves it exactly once.
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

    /// @notice Returns the hash of the most recently submitted (or updated) claim payload for a
    ///         given STID, or `bytes32(0)` if no claim has been submitted.
    function getClaimHash(bytes32 stid) external view returns (bytes32) {
        return _claimHash[stid];
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

    /// @notice Permissionless trigger that escalates a transaction from `PoICommitted` to
    ///         `EscalationL1` once TW1 has elapsed without a valid PoR.
    /// @dev v0.11.2 §3 / §4 — TW1 expiry opens the claim window. The function is intentionally
    ///      callable by anyone so liveness does not depend on a single party; whichever party has
    ///      an interest in resolving the off-chain leg can drive progress. No escrow movement
    ///      here — escrow stays locked until TW2 default-reverse or the DRP path.
    function pokeTW1(bytes32 stid) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();

        Transaction storage txn = _txs[stid];
        if (txn.state != State.PoICommitted) {
            revert InvalidState(uint8(State.PoICommitted), uint8(txn.state));
        }

        // Validator-side timestamp manipulation is bounded to a few seconds on Base whereas TW1
        // is on the minutes-to-hours scale; direct comparison is sound. Mirrors the suppression
        // pattern used in submitPoR (PR #4).
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= uint256(txn.committedAt) + uint256(txn.tw1)) revert EscalationNotDue();

        State previous = txn.state;
        txn.state = State.EscalationL1;
        emit StateChanged(stid, previous, State.EscalationL1);
    }

    /// @notice Submit a claim against an in-flight transaction whose TW1 has expired without a
    ///         valid PoR. Lazy-escalates from `PoICommitted` → `EscalationL1` if the TW1 window
    ///         has elapsed and the explicit `pokeTW1` (PR #5) has not yet fired.
    /// @dev Implements the eligible-claimant predicate of v0.11.2 §3 / §4. Claim payload semantics
    ///      are out of Part-1 scope; M2 stores only `keccak256(claimData)` and emits the raw
    ///      payload's presence through `ClaimSubmitted` for indexers, which reconstruct content
    ///      from the originating transaction's calldata. The two-stage claim lifecycle
    ///      (`submitClaim` then optional `updateClaim`) keeps the on-chain footprint to one slot
    ///      while preserving the off-chain editable surface that the spec allows during TW2.
    /// @param stid      Transaction identifier returned by `commitPoI`.
    /// @param claimData Claim payload bytes; only `keccak256(claimData)` is retained on-chain.
    function submitClaim(bytes32 stid, bytes calldata claimData) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();
        if (claimData.length == 0) revert InvalidClaimData();

        _expireTW1IfDue(stid);

        Transaction storage txn = _txs[stid];
        if (txn.state != State.EscalationL1) {
            revert InvalidState(uint8(State.EscalationL1), uint8(txn.state));
        }
        if (msg.sender != txn.eligibleClaimant) revert NotEligibleClaimant();
        // Window check mirrors the validator-drift-bounded comparison used elsewhere; TW2 is on
        // the hours scale and dwarfs validator timestamp manipulation by several orders of magnitude.
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > uint256(txn.committedAt) + uint256(txn.tw1) + uint256(txn.tw2)) {
            revert WindowExpired();
        }
        if (_claimHash[stid] != bytes32(0)) revert ClaimAlreadyExists();

        _claimHash[stid] = keccak256(claimData);
        emit ClaimSubmitted(stid, msg.sender);
    }

    /// @notice Update the claim payload for an in-flight transaction while the TW2 window is open.
    /// @dev Preserves the spec's "before claim acceptance" mutability window: the eligible
    ///      claimant may refine or correct the claim payload at any time within TW2 (and before
    ///      DRP invocation in PR #7 — that path is gated separately by the `EscalationL1` state
    ///      guard, which fails once `invokeDRP` transitions to `EscalationL2_DRP`). Only the
    ///      latest claim hash is retained on-chain; the historical revision chain is reconstructed
    ///      off-chain from the `ClaimSubmitted` / `ClaimUpdated` event sequence.
    /// @param stid      Transaction identifier returned by `commitPoI`.
    /// @param claimData New claim payload bytes; only `keccak256(claimData)` is retained on-chain.
    function updateClaim(bytes32 stid, bytes calldata claimData) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();
        if (claimData.length == 0) revert InvalidClaimData();

        Transaction storage txn = _txs[stid];
        if (txn.state != State.EscalationL1) {
            revert InvalidState(uint8(State.EscalationL1), uint8(txn.state));
        }
        if (msg.sender != txn.eligibleClaimant) revert NotEligibleClaimant();
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > uint256(txn.committedAt) + uint256(txn.tw1) + uint256(txn.tw2)) {
            revert WindowExpired();
        }
        if (_claimHash[stid] == bytes32(0)) revert NoClaimToUpdate();

        _claimHash[stid] = keccak256(claimData);
        emit ClaimUpdated(stid);
    }

    /// @notice Permissionless trigger that default-reverses a transaction once TW2 has elapsed
    ///         without a claim on record. Returns escrow to the originator atomically with the
    ///         terminal-state transition.
    /// @dev v0.11.2 §3 / §4 — the default-reverse path is reserved for transactions where the
    ///      eligible claimant chose not to file a claim within TW2. If a claim does exist when
    ///      TW2 elapses, the resolution path is the DRP boundary (`invokeDRP` in PR #7), not
    ///      this poker — `expireTW2` reverts `ClaimPending` in that case to surface the misuse.
    ///      Permissionless to keep liveness independent of any single party; same posture as
    ///      `pokeTW1` (PR #5). The lazy `_expireTW1IfDue` at entry lets a single call drive a
    ///      no-PoR no-claim transaction from `PoICommitted` directly to `Reversed` once both
    ///      windows have elapsed — observers see both `StateChanged` events in one tx, preserving
    ///      the lifecycle audit trail.
    function expireTW2(bytes32 stid) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();

        _expireTW1IfDue(stid);

        Transaction storage txn = _txs[stid];
        if (txn.state != State.EscalationL1) {
            revert InvalidState(uint8(State.EscalationL1), uint8(txn.state));
        }
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= uint256(txn.committedAt) + uint256(txn.tw1) + uint256(txn.tw2)) {
            revert EscalationNotDue();
        }
        if (_claimHash[stid] != bytes32(0)) revert ClaimPending();

        _finalizeReversed(stid);
    }

    /// @notice Cross the DRP boundary for a transaction that has reached `EscalationL1` with a
    ///         claim on record. Drives the state to `EscalationL2_DRP`, calls the frozen DRP
    ///         interface for a binary outcome, and atomically finalises to the resolved terminal
    ///         state (`Settled` or `Reversed`) within the TW3 window.
    /// @dev v0.11.2 §9 + addendum §2 — the Settlement Layer is the sole permitted caller of
    ///      `DRP.resolve(stid)` and the DRP returns a binary outcome. The single-invocation
    ///      invariant is enforced by `drpInvoked`; the time window is the full
    ///      `committedAt + tw1 + tw2 + tw3` envelope (after which `expireTW3` takes over via the
    ///      default-reverse path). Strict Checks-Effects-Interactions: state mutates to
    ///      `EscalationL2_DRP` and `drpInvoked = true` is set BEFORE the external `DRP.resolve`
    ///      call; the subsequent `_finalizeSettled` / `_finalizeReversed` is itself CEI-strict and
    ///      reentrancy-guarded by the outer `nonReentrant` modifier.
    /// @param stid Transaction identifier returned by `commitPoI`.
    function invokeDRP(bytes32 stid) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();

        Transaction storage txn = _txs[stid];
        if (txn.state != State.EscalationL1) {
            revert InvalidState(uint8(State.EscalationL1), uint8(txn.state));
        }
        if (msg.sender != txn.eligibleClaimant) revert NotEligibleClaimant();
        if (_claimHash[stid] == bytes32(0)) revert NoClaim();
        if (txn.drpInvoked) revert DRPAlreadyInvoked();
        uint256 absoluteExpiry = uint256(txn.committedAt) + uint256(txn.tw1) + uint256(txn.tw2) + uint256(txn.tw3);
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > absoluteExpiry) revert WindowExpired();

        // Effects: transition state + set drpInvoked BEFORE the external DRP call.
        State previous = txn.state;
        txn.state = State.EscalationL2_DRP;
        txn.drpInvoked = true;
        emit StateChanged(stid, previous, State.EscalationL2_DRP);
        emit DRPInvoked(stid);

        // Interaction: the single DRP boundary call. `nonReentrant` blocks any callback-driven
        // re-entry into Settlement; the DRP contract is constrained by the addendum to a single
        // invocation per STID, which the mock enforces locally as well.
        IDRP.Outcome outcome = DRP.resolve(stid);

        // Atomic finalisation. The helpers' `AlreadyFinalized` guard provides defence-in-depth
        // against any re-entry that somehow bypasses `nonReentrant`.
        if (outcome == IDRP.Outcome.Settled) {
            _finalizeSettled(stid);
        } else {
            _finalizeReversed(stid);
        }
    }

    /// @notice Permissionless default-reverse poker for the TW3 expiry path: a claimed transaction
    ///         whose dispute was not resolved through the DRP within the full
    ///         `committedAt + tw1 + tw2 + tw3` window default-reverses, returning escrow to the
    ///         originator.
    /// @dev v0.11.2 §3 / §9 — confirmed by Francis on 2026-05-14 with his own rationale on
    ///      permissionless liveness preservation ("permissionless liveness preserved; no
    ///      centralized rescue operation"), re-confirmed 2026-05-15.
    /// @dev Guarded on `EscalationL1`, not `EscalationL2_DRP`. `invokeDRP` is atomic — it
    ///      transitions to `EscalationL2_DRP`, calls `DRP.resolve`, and finalises in a single
    ///      transaction — so `EscalationL2_DRP` is never a persisted resting state and a guard on
    ///      it would be unreachable. A claimed transaction rests in `EscalationL1` until either
    ///      `invokeDRP` resolves it within the window or this poker default-reverses it after the
    ///      window. The `EscalationL1` escalation surface partitions cleanly by claim status:
    ///      no claim past TW2 → `expireTW2`; claim past the full window → `expireTW3`; claim still
    ///      inside the window → `invokeDRP`. The two pokers are mutually exclusive — `expireTW2`
    ///      requires no claim, `expireTW3` requires a claim. No lazy `_expireTW1IfDue` here: a
    ///      claim can only be filed via `submitClaim`, which itself requires `EscalationL1`, so a
    ///      claimed transaction is always already escalated.
    function expireTW3(bytes32 stid) external nonReentrant {
        if (!_exists[stid]) revert TransactionNotFound();

        Transaction storage txn = _txs[stid];
        if (txn.state != State.EscalationL1) {
            revert InvalidState(uint8(State.EscalationL1), uint8(txn.state));
        }
        if (_claimHash[stid] == bytes32(0)) revert NoClaim();
        uint256 absoluteExpiry = uint256(txn.committedAt) + uint256(txn.tw1) + uint256(txn.tw2) + uint256(txn.tw3);
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= absoluteExpiry) revert EscalationNotDue();

        _finalizeReversed(stid);
    }

    // ─── M2 stubs ────────────────────────────────────────────────────────────────────────────────

    /// @notice [M2] Retained as a reverting stub per the 15 May ratified decision to drop the
    ///         external recovery-hatch track. Always reverts `NotImplementedM1`.
    /// @dev SafeERC20 reverts atomically on transfer failure, so the "terminal state reached but
    ///      escrow not moved" condition is unreachable in the implemented finalisation helpers
    ///      (`_finalizeSettled` / `_finalizeReversed`); the recovery hatches have no observable
    ///      path to fire and are kept only as ABI placeholders to avoid a breaking selector change.
    function settle(bytes32) external pure {
        revert NotImplementedM1();
    }

    /// @notice [M2] Retained as a reverting stub per the 15 May ratified decision to drop the
    ///         external recovery-hatch track. Always reverts `NotImplementedM1`. See `settle`.
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

    /// @dev Drives a transaction to the `Reversed` terminal state and returns escrow to the
    ///      originator. Mirrors `_finalizeSettled` exactly under strict Checks-Effects-Interactions:
    ///      state mutation and `terminalMoved` are set before the external `safeTransfer`, and the
    ///      single-move invariant is enforced by the `AlreadyFinalized` guard at entry. Consumed by
    ///      `expireTW2` (TW2 default-reverse, PR #6) and by `invokeDRP` (DRP-Reversed outcome,
    ///      PR #7) plus `expireTW3` (TW3 default-reverse, PR #7). Callers must hold `nonReentrant`
    ///      at the external entry point.
    function _finalizeReversed(bytes32 stid) internal {
        Transaction storage txn = _txs[stid];
        if (txn.terminalMoved) revert AlreadyFinalized();

        State previous = txn.state;
        txn.state = State.Reversed;
        txn.terminalMoved = true;

        emit StateChanged(stid, previous, State.Reversed);
        emit Reversed(stid, txn.originator, txn.escrowAmount);

        USDC.safeTransfer(txn.originator, txn.escrowAmount);
    }

    /// @dev Lazy auto-escalator consumed by `submitClaim`. If the transaction is still in
    ///      `PoICommitted` and TW1 has elapsed, transitions to `EscalationL1` and emits
    ///      `StateChanged`; otherwise no-op. This preserves the spec's *"eligible claimant may
    ///      file a claim once TW1 expires"* contract without forcing claimants to first call
    ///      `pokeTW1` (PR #5) — the two surfaces (explicit poker and lazy escalation) co-exist
    ///      and converge on the same `EscalationL1` state. Callers must hold `nonReentrant` at the
    ///      external entry point.
    function _expireTW1IfDue(bytes32 stid) internal {
        Transaction storage txn = _txs[stid];
        if (txn.state != State.PoICommitted) return;
        // forge-lint: disable-next-line(incorrect-shift)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= uint256(txn.committedAt) + uint256(txn.tw1)) return;

        State previous = txn.state;
        txn.state = State.EscalationL1;
        emit StateChanged(stid, previous, State.EscalationL1);
    }
}
