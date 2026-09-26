// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISOS69069
/// @notice Interface to the deployed SOS69069 ledger. No transferable asset;
///         only records signed messages and exposes live Trust-Push counters.
interface ISOS69069 {
    /// @notice Records one signed message from `signer` intended for `intendedTo`.
    function recordSignature(
        address signer,
        address intendedTo,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external;

    /// @notice Records many signed messages from one `signer` to one `intendedTo` in one call.
    function recordSignatureOne(
        address signer,
        address intendedTo,
        bytes32[] calldata payloadHashes,
        bytes[] calldata signatures,
        string[] calldata metadatas
    ) external;

    /// @notice Computes the exact struct hash for a (signer, intendedTo, payloadHash, metadata) record.
    function recordStructHash(
        address signer,
        address intendedTo,
        bytes32 payloadHash,
        string calldata metadata
    ) external pure returns (bytes32);

    /// @notice Trust[user] - Push[user], computed live.
    function effectiveOf(address user) external view returns (int256);

    function pushCountOf(address user) external view returns (uint256);
    function trustCountOf(address user) external view returns (uint256);
}

/// @title SOS69069 dSOS
/// @notice Ownerless bearer-bond mechanism. Each bond is an ETH claim
///         created and redeemed only via signed records on the SOS69069
///         ledger. Redemption capacity comes from accumulated credits
///         earned as a holder's ledger effective score moves.
/// @dev Common bonds: creation and redemption records both target
///      SOS69069_LEDGER as intendedTo. Directed bonds: creation record
///      targets the recipient (mintTo); redemption record targets whoever
///      currently holds the bond (self).
contract dSOS {

    // =========================================================================
    // IDENTITY / CONSTANTS
    // =========================================================================

    /// @notice Address of the SOS69069 ledger this deployment reads and writes to.
    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;

    /// @notice Callable handle to the ledger at SOS69069_LEDGER.
    ISOS69069 public immutable SOS;

    /// @notice ETH locked per bond; required donation amount per bond.
    uint256 public constant UNIT = 0.000369 ether;

    /// @notice ETH floor common-bond redemptions will not draw below.
    uint256 public constant MIN_RESERVE = 0.05 ether;

    /// @notice Flat gas overhead added to measured gasUsed on relay.
    uint256 public constant INTRINSIC_GAS = 21_000;

    /// @notice Minimum SOS69069 effectiveOf() required to redeem.
    int256 public constant MIN_EFFECTIVE = -69069;

    /// @notice Maximum SOS69069 effectiveOf() required to redeem.
    int256 public constant MAX_EFFECTIVE = 69069;

    /// @notice Effective-score movement, in either direction, required per redemption credit.
    uint256 public constant CREDIT_STEP = 100;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // =========================================================================
    // STATE
    // =========================================================================

    /// @notice One ETH-backed bond.
    /// @param holder Current holder, entitled to relay this bond.
    /// @param active False once redeemed.
    /// @param earmarked True for a directed bond (protected principal, self-redeemed).
    /// @param creationRecordHash SOS69069 struct hash of this bond's creation record.
    struct Bond {
        address holder;
        bool active;
        bool earmarked;
        bytes32 creationRecordHash;
    }

    /// @notice All bonds by id.
    mapping(uint256 => Bond) public bonds;

    /// @notice Next bond id to mint.
    uint256 public nextBondId = 1;

    /// @notice ETH locked for active directed bonds; excluded from common redemptions and MIN_RESERVE.
    uint256 public totalEarmarked;

    /// @notice Bond ids held by an address.
    mapping(address => uint256[]) public bondsHeldBy;

    /// @dev bondId => index in bondsHeldBy[holder], for O(1) removal.
    mapping(uint256 => uint256) private _holderIndex;

    /// @notice Last effectiveOf() value checkpointed for a user's credit accounting.
    mapping(address => int256) public lastCheckpoint;

    /// @notice Accumulated, spendable, non-expiring redemption credits.
    mapping(address => uint256) public redemptionCredits;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event DonatedCommon(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event DonatedDirected(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);
    event Relayed(uint256 indexed bondId, address indexed from, address indexed to, int256 signerEffective, bool redeemed);
    event Redeemed(uint256 indexed bondId, address indexed holder, address indexed redeemTarget, bool earmarked, uint256 principalPaid, uint256 gasReimbursed);
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

    /// @notice Accepts plain ETH top-ups; no bond minted.
    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    /// @notice Mints 1 common bond to `mintTo`. Creation record: signer=msg.sender, intendedTo=SOS69069_LEDGER.
    /// @dev Gas: ~1 SSTORE-heavy struct write + 1 external recordSignature call.
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

    /// @notice Mints `count` common bonds to `mintTo` in one call, one creation record each.
    /// @dev Gas: 1 recordSignatureOne call (shared base cost) instead of `count` separate calls.
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

    /// @notice Mints 1 directed bond to `mintTo`. Creation record: signer=msg.sender, intendedTo=mintTo.
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

    /// @notice Mints `count` directed bonds to `mintTo` in one call, one creation record each.
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
    /// @dev delta = |current - lastCheckpoint|; credits += delta/100; checkpoint advances by
    ///      (credits earned * 100) only, preserving any sub-100 remainder. Callable by anyone, anytime.
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
    // RELAY (SIGN + FORWARD/REDEEM)
    // =========================================================================

    /// @notice Relays a bond to `to`. If `to` equals the bond's redeem target
    ///         (SOS69069_LEDGER for common, self for directed), the bond is
    ///         redeemed; otherwise it is forwarded. Always writes a signed
    ///         record to SOS69069_LEDGER tied to this action, atomically with
    ///         any payout — payment and record can never be separated.
    /// @dev Redemption requires effectiveOf(msg.sender) in [MIN_EFFECTIVE,
    ///      MAX_EFFECTIVE] and redemptionCredits[msg.sender] > 0 (synced
    ///      internally first). Gas: 1 recordSignature call + 1 ETH transfer on redeem.
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

            uint256 gasUsed = gasStart - gasleft() + INTRINSIC_GAS;
            uint256 gasCost = gasUsed * tx.gasprice;

            uint256 principalPaid;
            uint256 gasPaid;

            if (wasEarmarked) {
                totalEarmarked -= UNIT;
                principalPaid = UNIT;

                uint256 balance = address(this).balance;
                uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
                gasPaid = gasCost <= unearmarked ? gasCost : unearmarked;
            } else {
                uint256 balance = address(this).balance;
                uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
                uint256 available = unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;

                uint256 totalNeeded = UNIT + gasCost;
                uint256 payout = totalNeeded <= available ? totalNeeded : available;

                if (payout == totalNeeded || totalNeeded == 0) {
                    principalPaid = UNIT;
                    gasPaid = gasCost;
                } else {
                    principalPaid = (UNIT * payout) / totalNeeded;
                    gasPaid = payout - principalPaid;
                }
            }

            uint256 totalPayout = principalPaid + gasPaid;

            emit Redeemed(bondId, payee, redeemTarget, wasEarmarked, principalPaid, gasPaid);
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
    // VIEWS
    // =========================================================================

    function poolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice ETH available for common-bond redemption right now.
    function commonAvailable() external view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 unearmarked = balance > totalEarmarked ? balance - totalEarmarked : 0;
        return unearmarked > MIN_RESERVE ? unearmarked - MIN_RESERVE : 0;
    }

    /// @notice Address a bond must be relayed to in order to redeem it.
    function redeemTargetOf(uint256 bondId) external view returns (address) {
        Bond storage b = bonds[bondId];
        return b.earmarked ? b.holder : SOS69069_LEDGER;
    }

    /// @notice Whether relaying `bondId` to `to` would redeem it.
    function isRedeemable(uint256 bondId, address to) external view returns (bool) {
        Bond storage b = bonds[bondId];
        if (!b.active) return false;
        address redeemTarget = b.earmarked ? b.holder : SOS69069_LEDGER;
        return to == redeemTarget;
    }

    /// @notice Whether `user`'s effectiveOf() is within the redemption-eligible range.
    function isEligible(address user) external view returns (bool) {
        int256 eff = SOS.effectiveOf(user);
        return eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE;
    }

    /// @notice Live push/trust/effective values for `user` from the ledger.
    function signerMetrics(address user)
        external
        view
        returns (uint256 push, uint256 trust, int256 effective)
    {
        push = SOS.pushCountOf(user);
        trust = SOS.trustCountOf(user);
        effective = SOS.effectiveOf(user);
    }

    /// @notice Live view of what `user`'s redemption credits would be after a sync, without writing state.
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