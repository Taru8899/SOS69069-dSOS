// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISOS69069
/// @notice Interface to the deployed SOS69069 ledger. No transferable asset;
///         only records signed messages and exposes live Trust-Push counters.
interface ISOS69069 {
    function recordSignature(
        address signer,
        address intendedTo,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external;

    function recordSignatureOne(
        address signer,
        address intendedTo,
        bytes32[] calldata payloadHashes,
        bytes[] calldata signatures,
        string[] calldata metadatas
    ) external;

    function recordStructHash(
        address signer,
        address intendedTo,
        bytes32 payloadHash,
        string calldata metadata
    ) external pure returns (bytes32);

    function effectiveOf(address user) external view returns (int256);
    function pushCountOf(address user) external view returns (uint256);
    function trustCountOf(address user) external view returns (uint256);
}

/// @title SOS69069 dSOS
/// @notice Ownerless bearer-bond mechanism with two coexisting redemption
///         paths against the common pool: (1) redeeming a specific common
///         Bond object, and (2) redeeming a standalone credit directly,
///         with no bond required. Directed bonds are unaffected — always
///         tied to a specific Bond object, redeemable only by the current
///         holder to themself, principal always paid in full from
///         totalEarmarked.
/// @dev Common bonds: creation and redemption records target
///      SOS69069_LEDGER as intendedTo. Directed bonds: creation record
///      targets the recipient (mintTo); redemption record targets the
///      current holder (self). Standalone credit redemption: record
///      targets SOS69069_LEDGER, same as a common bond, but consumes a
///      credit instead of a Bond object. MIN_RESERVE floors unearmarked
///      funds against gas reimbursement for all three redemption paths.
contract dSOS {

    // =========================================================================
    // IDENTITY / CONSTANTS
    // =========================================================================

    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public immutable SOS;

    uint256 public constant UNIT = 0.000369 ether;
    uint256 public constant MIN_RESERVE = 0.05 ether;

    /// @notice Gas cost per non-zero calldata byte (post-Istanbul, EIP-2028, L1 rules).
    uint256 public constant GAS_PER_CALLDATA_BYTE = 16;

    /// @notice Fixed overhead covering tx base cost + post-measurement opcodes.
    /// @dev PLACEHOLDER — calibrate against real deployed gas measurements
    ///      before mainnet deployment. Cannot be changed post-deployment.
    uint256 public constant BASE_GAS_OVERHEAD = 23_500;

    int256 public constant MIN_EFFECTIVE = -69069;
    int256 public constant MAX_EFFECTIVE = 69069;
    uint256 public constant CREDIT_STEP = 100;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // =========================================================================
    // STATE
    // =========================================================================

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

    mapping(address => int256) public lastCheckpoint;
    mapping(address => uint256) public redemptionCredits;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event DonatedCommon(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event DonatedDirected(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event Relayed(uint256 indexed bondId, address indexed from, address indexed to, int256 signerEffective, bool redeemed);
    event Redeemed(uint256 indexed bondId, address indexed holder, address indexed redeemTarget, bool earmarked, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event CreditRedeemed(address indexed user, int256 signerEffective, uint256 principalPaid, uint256 gasReimbursed, uint256 gasUsedMeasured);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 creditsEarned, uint256 totalCredits, int256 newCheckpoint);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        SOS = ISOS69069(SOS69069_LEDGER);
    }

    // =========================================================================
    // DONATIONS (MINT)
    // =========================================================================

    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    /// @notice Mints 1 common bond to `mintTo`. Not gas-sponsored.
    function donateCommon(
        address mintTo,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(msg.value == UNIT, "value must equal UNIT");

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        bytes32 recordHash = SOS.recordStructHash(msg.sender, SOS69069_LEDGER, payloadHash, metadata);

        uint256 id = nextBondId++;
        bonds[id] = Bond({holder: mintTo, active: true, earmarked: false, creationRecordHash: recordHash});
        _addToHolder(mintTo, id);

        emit DonatedCommon(msg.sender, mintTo, id, 1, msg.value);
    }

    /// @notice Mints `count` common bonds to `mintTo`. Not gas-sponsored.
    function donateCommonBatch(
        address mintTo,
        uint256 count,
        bytes32[] calldata payloadHashes,
        bytes[] calldata signatures,
        string[] calldata metadatas
    ) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0, "count must be > 0");
        require(msg.value == UNIT * count, "value must equal UNIT * count");
        require(payloadHashes.length == count && signatures.length == count && metadatas.length == count, "array length mismatch");

        SOS.recordSignatureOne(msg.sender, SOS69069_LEDGER, payloadHashes, signatures, metadatas);

        uint256 startId = nextBondId;
        for (uint256 i = 0; i < count; i++) {
            bytes32 recordHash = SOS.recordStructHash(msg.sender, SOS69069_LEDGER, payloadHashes[i], metadatas[i]);
            uint256 id = nextBondId++;
            bonds[id] = Bond({holder: mintTo, active: true, earmarked: false, creationRecordHash: recordHash});
            _addToHolder(mintTo, id);
        }

        emit DonatedCommon(msg.sender, mintTo, startId, count, msg.value);
    }

    /// @notice Mints 1 directed bond to `mintTo`. Not gas-sponsored.
    function donateDirected(
        address mintTo,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(msg.value == UNIT, "value must equal UNIT");

        SOS.recordSignature(msg.sender, mintTo, payloadHash, signature, metadata);
        bytes32 recordHash = SOS.recordStructHash(msg.sender, mintTo, payloadHash, metadata);

        uint256 id = nextBondId++;
        bonds[id] = Bond({holder: mintTo, active: true, earmarked: true, creationRecordHash: recordHash});
        _addToHolder(mintTo, id);
        totalEarmarked += UNIT;

        emit DonatedDirected(msg.sender, mintTo, id, 1, msg.value);
    }

    /// @notice Mints `count` directed bonds to `mintTo`. Not gas-sponsored.
    function donateDirectedBatch(
        address mintTo,
        uint256 count,
        bytes32[] calldata payloadHashes,
        bytes[] calldata signatures,
        string[] calldata metadatas
    ) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0, "count must be > 0");
        require(msg.value == UNIT * count, "value must equal UNIT * count");
        require(payloadHashes.length == count && signatures.length == count && metadatas.length == count, "array length mismatch");

        SOS.recordSignatureOne(msg.sender, mintTo, payloadHashes, signatures, metadatas);

        uint256 startId = nextBondId;
        for (uint256 i = 0; i < count; i++) {
            bytes32 recordHash = SOS.recordStructHash(msg.sender, mintTo, payloadHashes[i], metadatas[i]);
            uint256 id = nextBondId++;
            bonds[id] = Bond({holder: mintTo, active: true, earmarked: true, creationRecordHash: recordHash});
            _addToHolder(mintTo, id);
        }

        totalEarmarked += UNIT * count;

        emit DonatedDirected(msg.sender, mintTo, startId, count, msg.value);
    }

    // =========================================================================
    // CREDITS
    // =========================================================================

    /// @notice Brings `user`'s redemption credits current from their live effectiveOf() score.
    function syncCredits(address user) public {
        int256 current = SOS.effectiveOf(user);
        int256 last = lastCheckpoint[user];
        int256 diff = current - last;
        uint256 absDiff = diff >= 0 ? uint256(diff) : uint256(-diff);
        uint256 earned = absDiff / CREDIT_STEP;

        if (earned > 0) {
            redemptionCredits[user] += earned;
            int256 consumed = int256(earned * CREDIT_STEP);
            lastCheckpoint[user] = diff >= 0 ? last + consumed : last - consumed;
            emit CreditsSynced(user, earned, redemptionCredits[user], lastCheckpoint[user]);
        }
    }

    // =========================================================================
    // BOND REDEMPTION (SIGN + FORWARD/REDEEM A SPECIFIC BOND)
    // =========================================================================

    /// @notice Relays a bond to `to`; redeems if `to` is the redeem target,
    ///         else forwards. Common-bond redemption spends 1 credit, same
    ///         as standalone credit redemption below, drawing from the same
    ///         commonAvailable() pool.
    function relay(
        uint256 bondId,
        address to,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external {
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
            eff = SOS.effectiveOf(msg.sender);
            require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");
            require(redemptionCredits[msg.sender] > 0, "no redemption credit");
        } else {
            eff = SOS.effectiveOf(msg.sender);
        }

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        if (willRedeem) {
            redemptionCredits[msg.sender] -= 1;

            address payee = msg.sender;
            bool wasEarmarked = b.earmarked;
            b.active = false;
            _removeFromHolder(payee, bondId);

            uint256 gasUsedMeasured = gasStart - gasleft();
            uint256 gasUsed = gasUsedMeasured + BASE_GAS_OVERHEAD + (msg.data.length * GAS_PER_CALLDATA_BYTE);
            uint256 gasCost = gasUsed * tx.gasprice;

            uint256 principalPaid;
            uint256 gasPaid;

            if (wasEarmarked) {
                totalEarmarked -= UNIT;
                principalPaid = UNIT;

                uint256 balance = address(this).balance;
                uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
                uint256 gasAvailable = unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;
                gasPaid = gasCost <= gasAvailable ? gasCost : gasAvailable;
            } else {
                (principalPaid, gasPaid) = _payFromCommonPool(UNIT, gasCost);
            }

            uint256 totalPayout = principalPaid + gasPaid;

            emit Redeemed(bondId, payee, redeemTarget, wasEarmarked, principalPaid, gasPaid, gasUsedMeasured);
            emit Relayed(bondId, payee, to, eff, true);

            if (totalPayout > 0) {
                (bool ok, ) = payable(payee).call{value: totalPayout}("");
                require(ok, "redeem payout failed");
            }
        } else {
            _removeFromHolder(msg.sender, bondId);
            b.holder = to;
            _addToHolder(to, bondId);

            emit Relayed(bondId, msg.sender, to, eff, false);
        }
    }

    // =========================================================================
    // STANDALONE CREDIT REDEMPTION (NO BOND REQUIRED)
    // =========================================================================

    /// @notice Redeems 1 standalone redemption credit directly for UNIT ETH
    ///         from the common pool, with no Bond object involved. Coexists
    ///         with common-bond redemption via relay(); both draw from the
    ///         same commonAvailable() pool and consume the same credit
    ///         balance — a user's total spendable credits are shared across
    ///         both paths, not tracked separately.
    /// @dev Record: signer=msg.sender, intendedTo=SOS69069_LEDGER, same as a
    ///      common bond's redemption record. Atomic: payment and ledger
    ///      record cannot be separated.
    function redeemCredit(
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external {
        uint256 gasStart = gasleft();

        syncCredits(msg.sender);
        int256 eff = SOS.effectiveOf(msg.sender);
        require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");
        require(redemptionCredits[msg.sender] > 0, "no redemption credit");

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);

        redemptionCredits[msg.sender] -= 1;

        uint256 gasUsedMeasured = gasStart - gasleft();
        uint256 gasUsed = gasUsedMeasured + BASE_GAS_OVERHEAD + (msg.data.length * GAS_PER_CALLDATA_BYTE);
        uint256 gasCost = gasUsed * tx.gasprice;

        (uint256 principalPaid, uint256 gasPaid) = _payFromCommonPool(UNIT, gasCost);
        uint256 totalPayout = principalPaid + gasPaid;

        emit CreditRedeemed(msg.sender, eff, principalPaid, gasPaid, gasUsedMeasured);

        if (totalPayout > 0) {
            (bool ok, ) = payable(msg.sender).call{value: totalPayout}("");
            require(ok, "credit redeem payout failed");
        }
    }

    /// @dev Shared payout math for anything drawing principal+gas from the
    ///      common (unearmarked) pool, scaling proportionally if thin,
    ///      never dipping below MIN_RESERVE.
    function _payFromCommonPool(uint256 principal, uint256 gasCost)
        internal
        view
        returns (uint256 principalPaid, uint256 gasPaid)
    {
        uint256 balance = address(this).balance;
        uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
        uint256 available = unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;

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

    // =========================================================================
    // VIEWS
    // =========================================================================

    function poolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function commonAvailable() external view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
        return unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;
    }

    function directedGasAvailable() external view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
        return unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;
    }

    function redeemTargetOf(uint256 bondId) external view returns (address) {
        Bond storage b = bonds[bondId];
        return b.earmarked ? b.holder : SOS69069_LEDGER;
    }

    function isRedeemable(uint256 bondId, address to) external view returns (bool) {
        Bond storage b = bonds[bondId];
        if (!b.active) return false;
        address redeemTarget = b.earmarked ? b.holder : SOS69069_LEDGER;
        return to == redeemTarget;
    }

    function isEligible(address user) external view returns (bool) {
        int256 eff = SOS.effectiveOf(user);
        return eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE;
    }

    function signerMetrics(address user)
        external
        view
        returns (uint256 push, uint256 trust, int256 effective)
    {
        push = SOS.pushCountOf(user);
        trust = SOS.trustCountOf(user);
        effective = SOS.effectiveOf(user);
    }

    /// @notice Live view of what `user`'s redemption credits would be after
    ///         a sync — this balance is shared and spendable by both
    ///         common-bond relay() redemption and standalone redeemCredit().
    function pendingCredits(address user) external view returns (uint256 creditsIfSynced) {
        int256 current = SOS.effectiveOf(user);
        int256 diff = current - lastCheckpoint[user];
        uint256 absDiff = diff >= 0 ? uint256(diff) : uint256(-diff);
        return redemptionCredits[user] + (absDiff / CREDIT_STEP);
    }

    function bondCountOf(address holder) external view returns (uint256) {
        return bondsHeldBy[holder].length;
    }

    function bondIdsOf(address holder) external view returns (uint256[] memory) {
        return bondsHeldBy[holder];
    }

    // =========================================================================
    // INTERNAL
    // =========================================================================

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