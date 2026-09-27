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
///         only via signed records on the SOS69069 ledger.
/// @dev Credits accrue from weighted push/trust activity (see syncCredits);
///      redemption additionally requires effectiveOf() within
///      [MIN_EFFECTIVE, MAX_EFFECTIVE] as an independent anti-hoarding gate.
///      Directed-bond principal is ring-fenced in totalEarmarked and always
///      paid in full; MIN_RESERVE floors unearmarked funds against gas
///      reimbursement across all redemption paths. Redemption reverts if
///      pool headroom is too thin to pay any principal at all, rather than
///      silently burning a credit for a zero payout.
contract dSOS {

    // ============================================================ CONSTANTS

    /// @notice SOS69069 ledger this deployment reads and writes.
    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public immutable SOS;

    uint256 public constant UNIT = 0.000369 ether;
    uint256 public constant MIN_RESERVE = 0.05 ether;
    uint256 public constant GAS_PER_CALLDATA_BYTE = 16;

    /// @dev Placeholder — calibrate against measured deployed gas before mainnet deploy.
    uint256 public constant BASE_GAS_OVERHEAD = 23_500;

    /// @notice Anti-hoarding redemption window on effectiveOf().
    int256 public constant MIN_EFFECTIVE = -69069;
    int256 public constant MAX_EFFECTIVE = 69069;

    uint256 public constant CREDIT_STEP = 100;
    uint256 public constant PUSH_WEIGHT = 1;
    uint256 public constant TRUST_WEIGHT = 1;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // =============================================================== STATE

    /// @param holder Current owner, entitled to relay.
    /// @param active False once redeemed.
    /// @param earmarked True = directed (self-redeemed, protected principal); false = common.
    /// @param creationRecordHash SOS69069 struct hash of this bond's mint record.
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

    mapping(address => uint256) public lastPush;
    mapping(address => uint256) public lastTrust;
    /// @notice Leftover weighted activity (0..CREDIT_STEP-1), carried across syncs.
    mapping(address => uint256) public activityRemainder;
    mapping(address => uint256) public redemptionCredits;

    // ============================================================== EVENTS

    event DonatedCommon(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event DonatedDirected(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event Relayed(uint256 indexed bondId, address indexed from, address indexed to, int256 signerEffective, bool redeemed);
    event Redeemed(uint256 indexed bondId, address indexed holder, address indexed redeemTarget, bool earmarked, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event CreditRedeemed(address indexed user, int256 signerEffective, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 creditsEarned, uint256 totalCredits, uint256 pushCount, uint256 trustCount);

    constructor() {
        SOS = ISOS69069(SOS69069_LEDGER);
    }

    /// @notice Plain ETH top-up; no bond minted, just joins the common pool.
    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    // ============================================================== MINTING

    /// @notice Mints 1 common bond to `mintTo`. Not gas-sponsored.
    function donateCommon(address mintTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(msg.value == UNIT, "value must equal UNIT");
        uint256 id = _mintOne(mintTo, SOS69069_LEDGER, false, payloadHash, signature, metadata);
        emit DonatedCommon(msg.sender, mintTo, id, 1, msg.value);
    }

    /// @notice Mints `count` common bonds to `mintTo`. Not gas-sponsored.
    /// @dev Trusts that SOS69069's recordSignatureOne wrote a matching,
    ///      verified record for every item; this contract does not
    ///      independently re-verify each signature. Safe against the
    ///      audited, immutable SOS69069 ledger this is pinned to — would
    ///      need re-review if ever pointed at a different ledger.
    function donateCommonBatch(address mintTo, uint256 count, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0 && msg.value == UNIT * count, "invalid count/value");
        require(payloadHashes.length == count && signatures.length == count && metadatas.length == count, "array length mismatch");
        SOS.recordSignatureOne(msg.sender, SOS69069_LEDGER, payloadHashes, signatures, metadatas);
        uint256 startId = _mintBatch(mintTo, SOS69069_LEDGER, false, payloadHashes, metadatas);
        emit DonatedCommon(msg.sender, mintTo, startId, count, msg.value);
    }

    /// @notice Mints 1 directed bond to `mintTo`. Not gas-sponsored.
    function donateDirected(address mintTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(msg.value == UNIT, "value must equal UNIT");
        uint256 id = _mintOne(mintTo, mintTo, true, payloadHash, signature, metadata);
        totalEarmarked += UNIT;
        emit DonatedDirected(msg.sender, mintTo, id, 1, msg.value);
    }

    /// @notice Mints `count` directed bonds to `mintTo`. Not gas-sponsored.
    /// @dev See donateCommonBatch — same trust assumption on recordSignatureOne.
    function donateDirectedBatch(address mintTo, uint256 count, bytes32[] calldata payloadHashes, bytes[] calldata signatures, string[] calldata metadatas) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0 && msg.value == UNIT * count, "invalid count/value");
        require(payloadHashes.length == count && signatures.length == count && metadatas.length == count, "array length mismatch");
        SOS.recordSignatureOne(msg.sender, mintTo, payloadHashes, signatures, metadatas);
        uint256 startId = _mintBatch(mintTo, mintTo, true, payloadHashes, metadatas);
        totalEarmarked += UNIT * count;
        emit DonatedDirected(msg.sender, mintTo, startId, count, msg.value);
    }

    /// @dev Writes the creation record, stores the bond, indexes it.
    function _mintOne(address mintTo, address intendedTo, bool earmarked, bytes32 payloadHash, bytes calldata signature, string calldata metadata) internal returns (uint256 id) {
        SOS.recordSignature(msg.sender, intendedTo, payloadHash, signature, metadata);
        bytes32 recordHash = SOS.recordStructHash(msg.sender, intendedTo, payloadHash, metadata);
        id = nextBondId++;
        bonds[id] = Bond(mintTo, true, earmarked, recordHash);
        _addToHolder(mintTo, id);
    }

    /// @dev Records were already written via recordSignatureOne; this only stores bonds.
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

    /// @notice Converts weighted push/trust increases since the last sync into credits.
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
    /// @dev Redemption requires syncCredits(caller) > 0, effectiveOf(caller) in range,
    ///      and non-zero pool headroom (reverts rather than burning a credit for nothing).
    function relay(uint256 bondId, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external {
        uint256 gasStart = gasleft();

        Bond storage b = bonds[bondId];
        require(b.active, "bond not active");
        require(b.holder == msg.sender, "not the current holder");
        require(to != address(0), "to is zero address");

        address redeemTarget = b.earmarked ? msg.sender : SOS69069_LEDGER;
        bool willRedeem = (to == redeemTarget);
        int256 eff;

        if (willRedeem) {
            syncCredits(msg.sender);
            require(redemptionCredits[msg.sender] > 0, "no redemption credit");
            eff = SOS.effectiveOf(msg.sender);
            require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");
        }

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        if (!willRedeem) {
            _removeFromHolder(msg.sender, bondId);
            b.holder = to;
            _addToHolder(to, bondId);
            emit Relayed(bondId, msg.sender, to, 0, false);
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
            require(principalPaid > 0, "pool too thin");
        }

        emit Redeemed(bondId, payee, redeemTarget, wasEarmarked, principalPaid, gasPaid, gasUsedMeasured);
        emit Relayed(bondId, payee, to, eff, true);

        uint256 totalPayout = principalPaid + gasPaid;
        if (totalPayout > 0) {
            (bool ok, ) = payable(payee).call{value: totalPayout}("");
            require(ok, "redeem payout failed");
        }
    }

    /// @notice Redeems 1 credit directly for UNIT ETH from the common pool; no bond required.
    /// @dev Requires redemptionCredits(caller) > 0, effectiveOf(caller) in range, and
    ///      non-zero pool headroom (reverts rather than burning a credit for nothing).
    function redeemCredit(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external {
        uint256 gasStart = gasleft();

        syncCredits(msg.sender);
        require(redemptionCredits[msg.sender] > 0, "no redemption credit");
        int256 eff = SOS.effectiveOf(msg.sender);
        require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        redemptionCredits[msg.sender] -= 1;

        (uint256 gasUsedMeasured, uint256 gasCost) = _gasAccounting(gasStart);
        (uint256 principalPaid, uint256 gasPaid) = _payFromCommonPool(UNIT, gasCost);
        require(principalPaid > 0, "pool too thin");

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

    /// @dev Unearmarked balance above MIN_RESERVE.
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

    // =================================================================VIEWS

    function poolBalance() external view returns (uint256) { return address(this).balance; }
    function commonAvailable() external view returns (uint256) { return _headroom(); }
    function directedGasAvailable() external view returns (uint256) { return _headroom(); }

    /// @notice Address a bond must be relayed to in order to redeem it.
    function redeemTargetOf(uint256 bondId) external view returns (address) {
        Bond storage b = bonds[bondId];
        return b.earmarked ? b.holder : SOS69069_LEDGER;
    }

    /// @notice Whether relaying `bondId` to `to` would redeem it.
    function isRedeemable(uint256 bondId, address to) external view returns (bool) {
        Bond storage b = bonds[bondId];
        return b.active && to == (b.earmarked ? b.holder : SOS69069_LEDGER);
    }

    /// @notice True iff user has a spendable credit AND effectiveOf() is within range.
    function isEligible(address user) external view returns (bool) {
        int256 eff = SOS.effectiveOf(user);
        return eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE && _pendingCredits(user) > 0;
    }

    /// @notice Raw push, trust, and effective values from the ledger.
    function signerMetrics(address user) external view returns (uint256 push, uint256 trust, int256 effective) {
        push = SOS.pushCountOf(user);
        trust = SOS.trustCountOf(user);
        effective = SOS.effectiveOf(user);
    }

    /// @notice Live credit balance as of a hypothetical syncCredits call now.
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