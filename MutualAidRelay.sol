// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISOS69069
/// @notice External SOS69069 ledger: no transferable asset, only signed records and live Push/Trust counters.
interface ISOS69069 {
    function recordSignature(address signer, address intendedTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external;
    function recordSignatureOne(address signer, address intendedTo, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external;
    function recordStructHash(address signer, address intendedTo, bytes32 payloadHash, string calldata metadata) external pure returns (bytes32);
    function effectiveOf(address user) external view returns (int256);
    function pushCountOf(address user) external view returns (uint256);
    function trustCountOf(address user) external view returns (uint256);
}

/// @title SOS69069 dSOS
/// @notice Ownerless ETH-backed bearer bonds and standalone credits, redeemed
///         via signed SOS69069 records. Multiple immutable pricing "modes"
///         each own a fully isolated common pool.
/// @dev Credits accrue from weighted push/trust activity, shared across all
///      modes/bond types. Redemption needs effectiveOf() in
///      [MIN_EFFECTIVE, MAX_EFFECTIVE] and always costs exactly 1 credit,
///      regardless of mode. Directed principal is ring-fenced in the global
///      totalEarmarked and always paid in full; its gas draws from its own
///      mode's pool. Common/standalone redemptions draw only from their own
///      mode's pool. MIN_RESERVE is enforced independently per mode.
contract dSOS {

    // ============================================================ CONSTANTS

    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public immutable SOS;

    uint256 public constant UNIT = 0.000369 ether;
    uint256 public constant MIN_RESERVE = 0.000999 ether;
    uint256 public constant GAS_PER_CALLDATA_BYTE = 16;
    /// @dev Placeholder — calibrate against measured deployed gas before mainnet deploy.
    uint256 public constant BASE_GAS_OVERHEAD = 23_500;

    int256 public constant MIN_EFFECTIVE = -69069;
    int256 public constant MAX_EFFECTIVE = 69069;

    uint256 public constant CREDIT_STEP = 100;
    uint256 public constant PUSH_WEIGHT = 1;
    uint256 public constant TRUST_WEIGHT = 1;
    uint256 public constant BASELINE_RECORDS = 100;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // =============================================================== ERRORS

    error ZeroAddress();
    error InvalidValue();
    error UnknownMode();
    error ModeBelowFloor();
    error ArrayLengthMismatch();
    error BondNotActive();
    error NotHolder();
    error NoCredit();
    error EffectiveOutOfRange();
    error PoolTooThin();
    error TransferFailed();

    // =============================================================== STATE

    /// @dev unit/records packed with exists into 1 slot (uint128+uint120+bool).
    struct Mode {
        uint128 unit;
        uint120 records; // comparative label vs 100-record baseline; no computational role
        bool exists;
    }

    mapping(uint256 => Mode) public modes;
    uint256 public nextModeId;

    /// @notice Each mode's own isolated common-pool ETH balance.
    mapping(uint256 => uint256) public modeCommonPool;

    /// @dev holder+active+earmarked+modeId packed into 1 slot; hash gets its own; principal its own.
    struct Bond {
        address holder;
        bool active;
        bool earmarked;
        uint64 modeId;
        bytes32 creationRecordHash;
        uint256 principal; // = modes[modeId].unit at mint time
    }

    mapping(uint256 => Bond) public bonds;
    uint256 public nextBondId = 1;

    /// @notice ETH locked for all active directed bonds, all modes; ring-fenced globally.
    uint256 public totalEarmarked;

    mapping(address => uint256[]) public bondsHeldBy;
    mapping(uint256 => uint256) private _holderIndex;

    mapping(address => uint256) public lastPush;
    mapping(address => uint256) public lastTrust;
    /// @notice Leftover weighted activity (0..CREDIT_STEP-1), carried across syncs.
    mapping(address => uint256) public activityRemainder;
    mapping(address => uint256) public redemptionCredits;

    // ============================================================== EVENTS

    event ModeCreated(uint256 indexed modeId, uint256 unit, uint256 records);
    event DonatedCommon(address indexed donor, address indexed mintTo, uint256 indexed modeId, uint256 startId, uint256 count, uint256 value);
    event DonatedDirected(address indexed donor, address indexed mintTo, uint256 indexed modeId, uint256 startId, uint256 count, uint256 value);
    /// @notice Emitted on every relay call. No effectiveOf() field — see Redeemed for that.
    event Relayed(uint256 indexed bondId, address indexed from, address indexed to, bool redeemed);
    event Redeemed(uint256 indexed bondId, address indexed holder, address indexed redeemTarget, bool earmarked, uint256 modeId, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured, int256 signerEffective);
    event CreditRedeemed(address indexed user, uint256 indexed modeId, int256 signerEffective, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 creditsEarned, uint256 totalCredits, uint256 pushCount, uint256 trustCount);

    constructor() {
        SOS = ISOS69069(SOS69069_LEDGER);
        _createMode(UNIT, BASELINE_RECORDS); // mode 0: baseline
    }

    /// @notice Plain ETH top-up; no bond minted, credits mode 0's pool only.
    receive() external payable {
        modeCommonPool[0] += msg.value;
        emit Donation(msg.sender, msg.value);
    }

    // ================================================================ MODES

    /// @notice Registers a new immutable pricing mode. Permissionless.
    ///         Always costs exactly 1 credit to redeem, regardless of records.
    function createMode(uint256 unit, uint256 records) external returns (uint256 modeId) {
        if (unit < UNIT || records < BASELINE_RECORDS) revert ModeBelowFloor();
        modeId = _createMode(unit, records);
    }

    function _createMode(uint256 unit, uint256 records) internal returns (uint256 modeId) {
        modeId = nextModeId++;
        modes[modeId] = Mode(uint128(unit), uint120(records), true);
        emit ModeCreated(modeId, unit, records);
    }

    // ============================================================== MINTING

    /// @notice Mints 1 common bond to `mintTo` under `modeId`. Not gas-sponsored.
    function donateCommon(uint256 modeId, address mintTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        Mode memory m = modes[modeId];
        if (!m.exists) revert UnknownMode();
        if (mintTo == address(0)) revert ZeroAddress();
        if (msg.value != m.unit) revert InvalidValue();

        uint256 id = _mintOne(mintTo, SOS69069_LEDGER, false, modeId, m.unit, payloadHash, signature, metadata);
        modeCommonPool[modeId] += msg.value;
        emit DonatedCommon(msg.sender, mintTo, modeId, id, 1, msg.value);
    }

    /// @notice Mints `count` common bonds to `mintTo` under `modeId`. Not gas-sponsored.
    /// @dev Trusts recordSignatureOne verified every item; safe against the
    ///      audited, immutable SOS69069 ledger this is pinned to.
    function donateCommonBatch(uint256 modeId, address mintTo, uint256 count, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external payable {
        Mode memory m = modes[modeId];
        if (!m.exists) revert UnknownMode();
        if (mintTo == address(0)) revert ZeroAddress();
        if (count == 0 || msg.value != uint256(m.unit) * count) revert InvalidValue();
        if (payloadHashes.length != count || signatures.length != count || metadatas.length != count) revert ArrayLengthMismatch();

        SOS.recordSignatureOne(msg.sender, SOS69069_LEDGER, payloadHashes, signatures, metadatas);
        uint256 startId = _mintBatch(mintTo, SOS69069_LEDGER, false, modeId, m.unit, payloadHashes, metadatas);
        modeCommonPool[modeId] += msg.value;
        emit DonatedCommon(msg.sender, mintTo, modeId, startId, count, msg.value);
    }

    /// @notice Mints 1 directed bond to `mintTo` under `modeId`. Not gas-sponsored.
    function donateDirected(uint256 modeId, address mintTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        Mode memory m = modes[modeId];
        if (!m.exists) revert UnknownMode();
        if (mintTo == address(0)) revert ZeroAddress();
        if (msg.value != m.unit) revert InvalidValue();

        uint256 id = _mintOne(mintTo, mintTo, true, modeId, m.unit, payloadHash, signature, metadata);
        totalEarmarked += msg.value;
        emit DonatedDirected(msg.sender, mintTo, modeId, id, 1, msg.value);
    }

    /// @notice Mints `count` directed bonds to `mintTo` under `modeId`. Not gas-sponsored.
    function donateDirectedBatch(uint256 modeId, address mintTo, uint256 count, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external payable {
        Mode memory m = modes[modeId];
        if (!m.exists) revert UnknownMode();
        if (mintTo == address(0)) revert ZeroAddress();
        if (count == 0 || msg.value != uint256(m.unit) * count) revert InvalidValue();
        if (payloadHashes.length != count || signatures.length != count || metadatas.length != count) revert ArrayLengthMismatch();

        SOS.recordSignatureOne(msg.sender, mintTo, payloadHashes, signatures, metadatas);
        uint256 startId = _mintBatch(mintTo, mintTo, true, modeId, m.unit, payloadHashes, metadatas);
        totalEarmarked += msg.value;
        emit DonatedDirected(msg.sender, mintTo, modeId, startId, count, msg.value);
    }

    /// @dev Writes the creation record, stores the bond, indexes it.
    function _mintOne(address mintTo, address intendedTo, bool earmarked, uint256 modeId, uint256 principal, bytes32 payloadHash, bytes calldata signature, string calldata metadata) internal returns (uint256 id) {
        SOS.recordSignature(msg.sender, intendedTo, payloadHash, signature, metadata);
        bytes32 recordHash = SOS.recordStructHash(msg.sender, intendedTo, payloadHash, metadata);
        id = nextBondId++;
        bonds[id] = Bond(mintTo, true, earmarked, uint64(modeId), recordHash, principal);
        _addToHolder(mintTo, id);
    }

    /// @dev Records were already written via recordSignatureOne; this only stores bonds.
    function _mintBatch(address mintTo, address intendedTo, bool earmarked, uint256 modeId, uint256 principal, bytes32[] calldata payloadHashes, string[] calldata metadatas) internal returns (uint256 startId) {
        startId = nextBondId;
        uint256 n = payloadHashes.length;
        for (uint256 i; i < n; ) {
            bytes32 recordHash = SOS.recordStructHash(msg.sender, intendedTo, payloadHashes[i], metadatas[i]);
            uint256 id = nextBondId++;
            bonds[id] = Bond(mintTo, true, earmarked, uint64(modeId), recordHash, principal);
            _addToHolder(mintTo, id);
            unchecked { ++i; }
        }
    }

    // ============================================================== CREDITS

    /// @notice Converts weighted push/trust increases since last sync into credits.
    /// @dev No-op if neither counter increased. Callable by anyone, anytime.
    function syncCredits(address user) public {
        uint256 currentPush = SOS.pushCountOf(user);
        uint256 currentTrust = SOS.trustCountOf(user);
        uint256 pushDelta = currentPush > lastPush[user] ? currentPush - lastPush[user] : 0;
        uint256 trustDelta = currentTrust > lastTrust[user] ? currentTrust - lastTrust[user] : 0;
        if (pushDelta == 0 && trustDelta == 0) return;

        uint256 total = activityRemainder[user] + pushDelta * PUSH_WEIGHT + trustDelta * TRUST_WEIGHT;
        uint256 earned = total / CREDIT_STEP;

        activityRemainder[user] = total % CREDIT_STEP;
        lastPush[user] = currentPush;
        lastTrust[user] = currentTrust;

        if (earned > 0) {
            redemptionCredits[user] += earned;
            emit CreditsSynced(user, earned, redemptionCredits[user], currentPush, currentTrust);
        }
    }

    // =========================================================== REDEMPTION

    /// @notice Relays a bond to `to`; redeems if `to` is the redeem target, else forwards.
    /// @dev Redemption spends exactly 1 credit, needs effectiveOf(caller) in range,
    ///      and draws from bonds[bondId].modeId's own pool (gas only for
    ///      directed bonds; principal + gas for common bonds).
    function relay(uint256 bondId, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external {
        uint256 gasStart = gasleft();

        Bond storage b = bonds[bondId];
        if (!b.active) revert BondNotActive();
        if (b.holder != msg.sender) revert NotHolder();
        if (to == address(0)) revert ZeroAddress();

        address redeemTarget = b.earmarked ? msg.sender : SOS69069_LEDGER;
        bool willRedeem = (to == redeemTarget);
        int256 eff;

        if (willRedeem) {
            syncCredits(msg.sender);
            if (redemptionCredits[msg.sender] == 0) revert NoCredit();
            eff = SOS.effectiveOf(msg.sender);
            if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) revert EffectiveOutOfRange();
        }

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        if (!willRedeem) {
            _removeFromHolder(msg.sender, bondId);
            b.holder = to;
            _addToHolder(to, bondId);
            emit Relayed(bondId, msg.sender, to, false);
            return;
        }

        redemptionCredits[msg.sender] -= 1;
        address payee = msg.sender;
        bool wasEarmarked = b.earmarked;
        uint256 modeId = b.modeId;
        uint256 principal = b.principal;
        b.active = false;
        _removeFromHolder(payee, bondId);

        (uint256 gasUsedMeasured, uint256 gasCost) = _gasAccounting(gasStart);
        uint256 principalPaid;
        uint256 gasPaid;

        if (wasEarmarked) {
            totalEarmarked -= principal;
            principalPaid = principal;
            uint256 headroom = _modeHeadroom(modeId);
            gasPaid = gasCost <= headroom ? gasCost : headroom;
            modeCommonPool[modeId] -= gasPaid;
        } else {
            (principalPaid, gasPaid) = _payFromModePool(modeId, principal, gasCost);
            if (principalPaid < principal / 2) revert PoolTooThin();
        }

        emit Redeemed(bondId, payee, redeemTarget, wasEarmarked, modeId, principalPaid, gasPaid, gasUsedMeasured, eff);
        emit Relayed(bondId, payee, to, true);

        uint256 totalPayout = principalPaid + gasPaid;
        if (totalPayout > 0) {
            (bool ok, ) = payable(payee).call{value: totalPayout}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Redeems 1 credit for `modes[modeId].unit` ETH from that mode's own pool; no bond required.
    function redeemCredit(uint256 modeId, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external {
        uint256 gasStart = gasleft();

        Mode memory m = modes[modeId];
        if (!m.exists) revert UnknownMode();

        syncCredits(msg.sender);
        if (redemptionCredits[msg.sender] == 0) revert NoCredit();
        int256 eff = SOS.effectiveOf(msg.sender);
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) revert EffectiveOutOfRange();

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        redemptionCredits[msg.sender] -= 1;

        (uint256 gasUsedMeasured, uint256 gasCost) = _gasAccounting(gasStart);
        (uint256 principalPaid, uint256 gasPaid) = _payFromModePool(modeId, m.unit, gasCost);
        if (principalPaid < uint256(m.unit) / 2) revert PoolTooThin();

        emit CreditRedeemed(msg.sender, modeId, eff, principalPaid, gasPaid, gasUsedMeasured);

        uint256 totalPayout = principalPaid + gasPaid;
        if (totalPayout > 0) {
            (bool ok, ) = payable(msg.sender).call{value: totalPayout}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @dev Measured internal gas + this call's calldata cost + fixed overhead, in wei.
    function _gasAccounting(uint256 gasStart) internal view returns (uint256 measured, uint256 cost) {
        unchecked { measured = gasStart - gasleft(); }
        cost = (measured + BASE_GAS_OVERHEAD + msg.data.length * GAS_PER_CALLDATA_BYTE) * tx.gasprice;
    }

    /// @dev ETH above MIN_RESERVE in a specific mode's isolated pool.
    function _modeHeadroom(uint256 modeId) internal view returns (uint256) {
        uint256 pool = modeCommonPool[modeId];
        return pool > MIN_RESERVE ? pool - MIN_RESERVE : 0;
    }

    /// @dev Pays principal+gas from modeId's own pool, scaling proportionally
    ///      if thin, and decrements that pool by the actual payout.
    function _payFromModePool(uint256 modeId, uint256 principal, uint256 gasCost) internal returns (uint256 principalPaid, uint256 gasPaid) {
        uint256 available = _modeHeadroom(modeId);
        uint256 totalNeeded = principal + gasCost;
        uint256 payout = totalNeeded <= available ? totalNeeded : available;

        if (payout == totalNeeded || totalNeeded == 0) {
            principalPaid = principal;
            gasPaid = gasCost;
        } else {
            principalPaid = (principal * payout) / totalNeeded;
            gasPaid = payout - principalPaid;
        }
        modeCommonPool[modeId] -= (principalPaid + gasPaid);
    }

    // =================================================================VIEWS

    function poolBalance() external view returns (uint256) { return address(this).balance; }
    function modeAvailable(uint256 modeId) external view returns (uint256) { return _modeHeadroom(modeId); }

    function redeemTargetOf(uint256 bondId) external view returns (address) {
        Bond storage b = bonds[bondId];
        return b.earmarked ? b.holder : SOS69069_LEDGER;
    }

    function isRedeemable(uint256 bondId, address to) external view returns (bool) {
        Bond storage b = bonds[bondId];
        return b.active && to == (b.earmarked ? b.holder : SOS69069_LEDGER);
    }

    /// @notice True iff user has a spendable credit AND effectiveOf() is within range.
    function isEligible(address user) external view returns (bool) {
        int256 eff = SOS.effectiveOf(user);
        return eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE && _pendingCredits(user) > 0;
    }

    function signerMetrics(address user) external view returns (uint256 push, uint256 trust, int256 effective) {
        push = SOS.pushCountOf(user);
        trust = SOS.trustCountOf(user);
        effective = SOS.effectiveOf(user);
    }

    function pendingCredits(address user) external view returns (uint256) {
        return _pendingCredits(user);
    }

    /// @dev Shared by pendingCredits and isEligible to avoid an external self-call.
    function _pendingCredits(address user) internal view returns (uint256) {
        uint256 currentPush = SOS.pushCountOf(user);
        uint256 currentTrust = SOS.trustCountOf(user);
        uint256 pushDelta = currentPush > lastPush[user] ? currentPush - lastPush[user] : 0;
        uint256 trustDelta = currentTrust > lastTrust[user] ? currentTrust - lastTrust[user] : 0;
        uint256 weighted = pushDelta * PUSH_WEIGHT + trustDelta * TRUST_WEIGHT;
        return redemptionCredits[user] + (activityRemainder[user] + weighted) / CREDIT_STEP;
    }

    /// @notice A mode's percentage cost vs. the 100-record baseline (records itself, since baseline = 100).
    function modePercentOfBaseline(uint256 modeId) external view returns (uint256) {
        if (!modes[modeId].exists) revert UnknownMode();
        return modes[modeId].records;
    }

    function bondCountOf(address holder) external view returns (uint256) { return bondsHeldBy[holder].length; }
    function bondIdsOf(address holder) external view returns (uint256[] memory) { return bondsHeldBy[holder]; }

    // ============================================================== INTERNAL

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