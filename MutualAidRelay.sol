// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISOS69069
/// @notice Interface to the deployed SOS69069 ledger. No transferable asset;
///         only records signed messages and exposes live Trust-Push counters.
interface ISOS69069 {
    function recordSignature(address signer, address intendedTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external;
    function recordSignatureOne(address signer, address intendedTo, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external;
    function recordStructHash(address signer, address intendedTo, bytes32 payloadHash, string calldata metadata) external pure returns (bytes32);
    function effectiveOf(address user) external view returns (int256);
    function pushCountOf(address user) external view returns (uint256);
    function trustCountOf(address user) external view returns (uint256);
}

/// @title SOS69069 dSOS
/// @notice Ownerless bearer-bond mechanism. Common bonds: creation and
///         redemption records target SOS69069_LEDGER. Directed bonds:
///         creation targets the recipient (mintTo); redemption targets the
///         current holder (self); principal always paid in full from
///         totalEarmarked. A standalone redeemCredit() path also draws UNIT
///         from the common pool with no bond required, sharing the same
///         credit balance as common-bond redemption.
/// @dev Credit accounting: effectiveOf() is clamped to [MIN_EFFECTIVE,
///      MAX_EFFECTIVE] = [-69069, +69069]. Every sync adds the ABSOLUTE
///      movement since the last sync into a running cumulative total —
///      movement in opposite directions ADDS, never cancels (+20 then -80,
///      synced after each, sums to 100 total = 1 credit, even though net
///      change is -60). Requires syncCredits to be called between
///      individual effective changes to count each one; a sync spanning
///      multiple unobserved changes can only measure their net effect.
///      MIN_RESERVE floors unearmarked funds against gas reimbursement for
///      all redemption paths; directed principal bypasses it entirely.
contract dSOS {

    // ============================================================= CONSTANTS

    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public immutable SOS;

    uint256 public constant UNIT = 0.000369 ether;
    uint256 public constant MIN_RESERVE = 0.05 ether;
    uint256 public constant GAS_PER_CALLDATA_BYTE = 16;
    /// @dev PLACEHOLDER — calibrate against real deployed gas before mainnet deploy.
    uint256 public constant BASE_GAS_OVERHEAD = 23_500;

    /// @notice Bounds for redemption eligibility AND credit accounting.
    int256 public constant MIN_EFFECTIVE = -69069;
    int256 public constant MAX_EFFECTIVE = 69069;
    uint256 public constant CREDIT_STEP = 100;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // ================================================================ STATE

    struct Bond {
        address holder;
        bool active;
        bool earmarked;
        bytes32 creationRecordHash;
    }

    mapping(uint256 => Bond) public bonds;
    uint256 public nextBondId = 1;
    uint256 public totalEarmarked;

    mapping(address => uint256[]) public bondsHeldBy;
    mapping(uint256 => uint256) private _holderIndex;

    /// @notice Last observed (clamped) effectiveOf() value for a user.
    mapping(address => int256) public lastEffective;

    /// @notice Leftover cumulative absolute movement not yet converted to a
    ///         credit (0-99). Carries forward across syncs so partial
    ///         movement is never lost, only pending.
    mapping(address => uint256) public movementRemainder;

    /// @notice Accumulated, spendable, non-expiring redemption credits.
    mapping(address => uint256) public redemptionCredits;

    // =============================================================== EVENTS

    event DonatedCommon(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event DonatedDirected(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event Relayed(uint256 indexed bondId, address indexed from, address indexed to, int256 signerEffective, bool redeemed);
    event Redeemed(uint256 indexed bondId, address indexed holder, address indexed redeemTarget, bool earmarked, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event CreditRedeemed(address indexed user, int256 signerEffective, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 creditsEarned, uint256 totalCredits, int256 observedEffective);

    constructor() {
        SOS = ISOS69069(SOS69069_LEDGER);
    }

    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    // ============================================================= MINTING

    function donateCommon(address mintTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(msg.value == UNIT, "value must equal UNIT");
        uint256 id = _mintOne(mintTo, SOS69069_LEDGER, false, payloadHash, signature, metadata);
        emit DonatedCommon(msg.sender, mintTo, id, 1, msg.value);
    }

    function donateCommonBatch(address mintTo, uint256 count, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0 && msg.value == UNIT * count, "invalid count/value");
        require(payloadHashes.length == count && signatures.length == count && metadatas.length == count, "array length mismatch");
        SOS.recordSignatureOne(msg.sender, SOS69069_LEDGER, payloadHashes, signatures, metadatas);
        uint256 startId = _mintBatch(mintTo, SOS69069_LEDGER, false, payloadHashes, metadatas);
        emit DonatedCommon(msg.sender, mintTo, startId, count, msg.value);
    }

    function donateDirected(address mintTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(msg.value == UNIT, "value must equal UNIT");
        uint256 id = _mintOne(mintTo, mintTo, true, payloadHash, signature, metadata);
        totalEarmarked += UNIT;
        emit DonatedDirected(msg.sender, mintTo, id, 1, msg.value);
    }

    function donateDirectedBatch(address mintTo, uint256 count, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0 && msg.value == UNIT * count, "invalid count/value");
        require(payloadHashes.length == count && signatures.length == count && metadatas.length == count, "array length mismatch");
        SOS.recordSignatureOne(msg.sender, mintTo, payloadHashes, signatures, metadatas);
        uint256 startId = _mintBatch(mintTo, mintTo, true, payloadHashes, metadatas);
        totalEarmarked += UNIT * count;
        emit DonatedDirected(msg.sender, mintTo, startId, count, msg.value);
    }

    /// @dev Single-bond mint: writes the creation record, stores the bond, indexes it.
    function _mintOne(address mintTo, address intendedTo, bool earmarked, bytes32 payloadHash, bytes calldata signature, string calldata metadata) internal returns (uint256 id) {
        SOS.recordSignature(msg.sender, intendedTo, payloadHash, signature, metadata);
        bytes32 recordHash = SOS.recordStructHash(msg.sender, intendedTo, payloadHash, metadata);
        id = nextBondId++;
        bonds[id] = Bond(mintTo, true, earmarked, recordHash);
        _addToHolder(mintTo, id);
    }

    /// @dev Batch mint: caller already wrote all records via recordSignatureOne; this just stores bonds.
    function _mintBatch(address mintTo, address intendedTo, bool earmarked, bytes32[] calldata payloadHashes, string[] calldata metadatas) internal returns (uint256 startId) {
        startId = nextBondId;
        for (uint256 i = 0; i < payloadHashes.length; i++) {
            bytes32 recordHash = SOS.recordStructHash(msg.sender, intendedTo, payloadHashes[i], metadatas[i]);
            uint256 id = nextBondId++;
            bonds[id] = Bond(mintTo, true, earmarked, recordHash);
            _addToHolder(mintTo, id);
        }
    }

    // ============================================================== CREDITS

    /// @dev Clamps a raw effectiveOf() reading into [MIN_EFFECTIVE, MAX_EFFECTIVE].
    function _clamp(int256 value) internal pure returns (int256) {
        if (value > MAX_EFFECTIVE) return MAX_EFFECTIVE;
        if (value < MIN_EFFECTIVE) return MIN_EFFECTIVE;
        return value;
    }

    /// @notice Adds |current - lastEffective| (both clamped) to the user's
    ///         cumulative movement total and converts every full 100 points
    ///         of TOTAL accumulated movement — summed across all directions
    ///         and all past syncs — into 1 permanent credit. Opposite-direction
    ///         moves add together rather than canceling.
    /// @dev Callable by anyone, anytime. Must be called between individual
    ///      effective changes to count each one; see contract-level NatSpec.
    function syncCredits(address user) public {
        int256 current = _clamp(SOS.effectiveOf(user));
        int256 last = lastEffective[user];
        uint256 diff = current >= last ? uint256(current - last) : uint256(last - current);

        if (diff > 0) {
            uint256 total = movementRemainder[user] + diff;
            uint256 earned = total / CREDIT_STEP;
            movementRemainder[user] = total % CREDIT_STEP;
            lastEffective[user] = current;

            if (earned > 0) {
                redemptionCredits[user] += earned;
                emit CreditsSynced(user, earned, redemptionCredits[user], current);
            }
        }
    }

    // ========================================================= RELAY/REDEEM

    function relay(uint256 bondId, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external {
        uint256 gasStart = gasleft();

        Bond storage b = bonds[bondId];
        require(b.active, "bond not active");
        require(b.holder == msg.sender, "not the current holder");
        require(to != address(0), "to is zero address");

        address redeemTarget = b.earmarked ? msg.sender : SOS69069_LEDGER;
        bool willRedeem = (to == redeemTarget);

        if (willRedeem) {
            syncCredits(msg.sender);
            require(redemptionCredits[msg.sender] > 0, "no redemption credit");
        }
        int256 eff = SOS.effectiveOf(msg.sender);
        if (willRedeem) require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        if (!willRedeem) {
            _removeFromHolder(msg.sender, bondId);
            b.holder = to;
            _addToHolder(to, bondId);
            emit Relayed(bondId, msg.sender, to, eff, false);
            return;
        }

        redemptionCredits[msg.sender] -= 1;
        address payee = msg.sender;
        bool wasEarmarked = b.earmarked;
        b.active = false;
        _removeFromHolder(payee, bondId);

        (uint256 gasUsedMeasured, uint256 gasCost) = _gasAccounting(gasStart);
        uint256 principalPaid;
        uint256 gasPaid;

        if (wasEarmarked) {
            totalEarmarked -= UNIT;
            principalPaid = UNIT;
            uint256 headroom = _headroom();
            gasPaid = gasCost <= headroom ? gasCost : headroom;
        } else {
            (principalPaid, gasPaid) = _payFromCommonPool(UNIT, gasCost);
        }

        emit Redeemed(bondId, payee, redeemTarget, wasEarmarked, principalPaid, gasPaid, gasUsedMeasured);
        emit Relayed(bondId, payee, to, eff, true);

        uint256 totalPayout = principalPaid + gasPaid;
        if (totalPayout > 0) {
            (bool ok, ) = payable(payee).call{value: totalPayout}("");
            require(ok, "redeem payout failed");
        }
    }

    function redeemCredit(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external {
        uint256 gasStart = gasleft();

        syncCredits(msg.sender);
        int256 eff = SOS.effectiveOf(msg.sender);
        require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");
        require(redemptionCredits[msg.sender] > 0, "no redemption credit");

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        redemptionCredits[msg.sender] -= 1;

        (uint256 gasUsedMeasured, uint256 gasCost) = _gasAccounting(gasStart);
        (uint256 principalPaid, uint256 gasPaid) = _payFromCommonPool(UNIT, gasCost);

        emit CreditRedeemed(msg.sender, eff, principalPaid, gasPaid, gasUsedMeasured);

        uint256 totalPayout = principalPaid + gasPaid;
        if (totalPayout > 0) {
            (bool ok, ) = payable(msg.sender).call{value: totalPayout}("");
            require(ok, "credit redeem payout failed");
        }
    }

    /// @dev Measured internal gas + this call's calldata cost + fixed overhead, in wei.
    function _gasAccounting(uint256 gasStart) internal view returns (uint256 measured, uint256 cost) {
        measured = gasStart - gasleft();
        cost = (measured + BASE_GAS_OVERHEAD + msg.data.length * GAS_PER_CALLDATA_BYTE) * tx.gasprice;
    }

    /// @dev Unearmarked balance above MIN_RESERVE — the shared floor-protected headroom.
    function _headroom() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
        return unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;
    }

    /// @dev Pays principal+gas from headroom, scaling both proportionally if thin.
    function _payFromCommonPool(uint256 principal, uint256 gasCost) internal view returns (uint256 principalPaid, uint256 gasPaid) {
        uint256 available = _headroom();
        uint256 totalNeeded = principal + gasCost;
        uint256 payout = totalNeeded <= available ? totalNeeded : available;

        if (payout == totalNeeded || totalNeeded == 0) {
            principalPaid = principal;
            gasPaid = gasCost;
        } else {
            principalPaid = (principal * payout) / totalNeeded;
            gasPaid = payout - principalPaid;
        }
    }

    // =============================================================== VIEWS

    function poolBalance() external view returns (uint256) { return address(this).balance; }
    function commonAvailable() external view returns (uint256) { return _headroom(); }
    function directedGasAvailable() external view returns (uint256) { return _headroom(); }

    function redeemTargetOf(uint256 bondId) external view returns (address) {
        Bond storage b = bonds[bondId];
        return b.earmarked ? b.holder : SOS69069_LEDGER;
    }

    function isRedeemable(uint256 bondId, address to) external view returns (bool) {
        Bond storage b = bonds[bondId];
        return b.active && to == (b.earmarked ? b.holder : SOS69069_LEDGER);
    }

    function isEligible(address user) external view returns (bool) {
        int256 eff = SOS.effectiveOf(user);
        return eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE;
    }

    function signerMetrics(address user) external view returns (uint256 push, uint256 trust, int256 effective) {
        push = SOS.pushCountOf(user);
        trust = SOS.trustCountOf(user);
        effective = SOS.effectiveOf(user);
    }

    /// @notice Live view of credits after a sync, using the same cumulative
    ///         absolute-movement logic as syncCredits. Only reflects movement
    ///         since the last actual sync — see contract-level NatSpec caveat.
    function pendingCredits(address user) external view returns (uint256) {
        int256 current = _clamp(SOS.effectiveOf(user));
        int256 last = lastEffective[user];
        uint256 diff = current >= last ? uint256(current - last) : uint256(last - current);
        return redemptionCredits[user] + (movementRemainder[user] + diff) / CREDIT_STEP;
    }

    function bondCountOf(address holder) external view returns (uint256) { return bondsHeldBy[holder].length; }
    function bondIdsOf(address holder) external view returns (uint256[] memory) { return bondsHeldBy[holder]; }

    // ============================================================ INTERNAL

    function _addToHolder(address holder, uint256 bondId) internal {
        bondsHeldBy[holder].push(bondId);
        _holderIndex[bondId] = bondsHeldBy[holder].length - 1;
    }

    function _removeFromHolder(address holder, uint256 bondId) internal {
        uint256[] storage arr = bondsHeldBy[holder];
        uint256 idx = _holderIndex[bondId];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            uint256 lastBondId = arr[lastIdx];
            arr[idx] = lastBondId;
            _holderIndex[lastBondId] = idx;
        }
        arr.pop();
        delete _holderIndex[bondId];
    }
}