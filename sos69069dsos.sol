// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title ISOS69069
interface ISOS69069 {
    function recordSignature(address signer, address intendedTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external;
    function recordStructHash(address signer, address intendedTo, bytes32 payloadHash, string calldata metadata) external pure returns (bytes32);
    function effectiveOf(address user) external view returns (int256);
    function trustCountOf(address user) external view returns (uint256);
    function statsOf(address user) external view returns (uint256 pushCount, uint256 trustCount, int256 effective);
}

/// @title SOS69069 dSOS
/// @notice Ownerless. Three offer types (B/T/P) + credit pool with sawtooth rate.
///         B = exact-seller (non-cancellable). T = public Trust buy. P = Push service.
///         Credits from trust only. All state-changing calls refund measured gas from common pool
///         without touching MIN_RESERVE.
contract dSOS {
    // ───────────────────────────────────────────── Constants
    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public constant SOS = ISOS69069(SOS69069_LEDGER);

    uint256 public constant UNIT            = 0.006 ether;
    uint256 public constant MIN_RESERVE     = 0.000999 ether;
    uint256 public constant RATE_STEP       = 1001;
    uint256 public constant BASE_RATE_PCT   = 30;
    uint256 public constant CYCLE_STEPS     = 71;
    uint256 public constant DEAD_ZONE_POS   = 70;
    uint256 public constant CANCEL_BLOCKS   = 50_400;   // ≈ 7 days
    uint256 public constant GAS_OVERHEAD    = 25_000;

    // ───────────────────────────────────────────── Errors
    error ZeroAddress();
    error InvalidValue();
    error OfferNotActive();
    error NotHolder();
    error NotDonor();
    error TooEarlyToCancel();
    error CannotCancelB();
    error NoCredit();
    error PoolTooThin();
    error TransferFailed();
    error Reentrant();

    // ───────────────────────────────────────────── Storage
    enum OfferType { B, T, P }

    // slot0: holder (160) + principal (96)
    // slot1: donor (160) + active (8) + index (64) + createdBlock (64) + kind (8) → fits in 160+8+64+64+8 = 304 bits → 2 slots
    // slot2: recordHash
    struct Offer {
        address holder;
        uint96  principal;
        address donor;
        bool    active;
        uint64  index;
        uint64  createdBlock;
        OfferType kind;
        bytes32 recordHash;
    }

    struct Account {
        uint128 lastTrust;
        uint128 credits;
    }

    mapping(uint256 => Offer) private _offers;
    mapping(address => Account) private _acct;
    mapping(address => uint256[]) public offersHeldBy;

    uint64  public nextOfferId = 1;
    bool    private _locked;
    uint128 public totalEarmarked;

    // ───────────────────────────────────────────── Events
    event OfferCreated(uint256 indexed id, OfferType kind, address indexed donor, address indexed to, uint256 principal, uint256 cancelBlock);
    event OfferTransferred(uint256 indexed id, address indexed from, address indexed to);
    event OfferRedeemed(uint256 indexed id, address indexed donor, address indexed holder, uint256 principal);
    event OfferCancelled(uint256 indexed id, address indexed donor, uint256 principal);
    event CommonDonation(address indexed donor, uint256 amount);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 earned, uint256 total, uint256 push, uint256 trust);
    event CreditRedeemed(address indexed user, int256 eff, uint256 ratePct, uint256 paid);
    event GasRefunded(address indexed to, uint256 gasUsed, uint256 amount);

    // ───────────────────────────────────────────── Modifiers
    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    // ───────────────────────────────────────────── Funding
    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    function donateCommon(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable nonReentrant {
        uint256 g = gasleft();
        if (msg.value == 0) revert InvalidValue();
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        emit CommonDonation(msg.sender, msg.value);
        _refund(msg.sender, g);
    }

    // ───────────────────────────────────────────── Offers
    function createOffer(
        OfferType kind,
        address to,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external payable nonReentrant {
        uint256 g = gasleft();
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0 || msg.value > type(uint96).max) revert InvalidValue();

        uint256 id = nextOfferId++;
        bytes32 rh = SOS.recordStructHash(msg.sender, to, payloadHash, metadata);

        _offers[id] = Offer({
            holder: to,
            principal: uint96(msg.value),
            donor: msg.sender,
            active: true,
            index: _push(to, id),
            createdBlock: uint64(block.number),
            kind: kind,
            recordHash: rh
        });
        totalEarmarked += uint128(msg.value);

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);
        emit OfferCreated(id, kind, msg.sender, to, msg.value, block.number + CANCEL_BLOCKS);
        _refund(msg.sender, g);
    }

    function transferOffer(uint256 id, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        uint256 g = gasleft();
        Offer storage o = _offers[id];
        if (!o.active) revert OfferNotActive();
        if (o.holder != msg.sender) revert NotHolder();
        if (to == address(0)) revert ZeroAddress();

        _pop(msg.sender, o.index);
        o.index = _push(to, id);
        o.holder = to;

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);
        emit OfferTransferred(id, msg.sender, to);
        _refund(msg.sender, g);
    }

    function redeemOffer(uint256 id, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        uint256 g = gasleft();
        Offer storage o = _offers[id];
        if (!o.active) revert OfferNotActive();
        if (o.holder != msg.sender) revert NotHolder();

        address donor = o.donor;
        uint96 principal = o.principal;

        o.active = false;
        totalEarmarked -= principal;
        _pop(msg.sender, o.index);

        SOS.recordSignature(msg.sender, donor, payloadHash, signature, metadata);
        emit OfferRedeemed(id, donor, msg.sender, principal);
        _send(msg.sender, principal);
        _refund(msg.sender, g);
    }

    function cancelOffer(uint256 id) external nonReentrant {
        uint256 g = gasleft();
        Offer storage o = _offers[id];
        if (!o.active) revert OfferNotActive();
        if (o.donor != msg.sender) revert NotDonor();
        if (o.kind == OfferType.B) revert CannotCancelB();
        if (block.number < uint256(o.createdBlock) + CANCEL_BLOCKS) revert TooEarlyToCancel();

        uint96 principal = o.principal;
        o.active = false;
        totalEarmarked -= principal;
        _pop(o.holder, o.index);

        emit OfferCancelled(id, msg.sender, principal);
        _send(msg.sender, principal);
        _refund(msg.sender, g);
    }

    // ───────────────────────────────────────────── Credits
    function syncCredits(address user) external nonReentrant returns (uint256 push, uint256 trust) {
        uint256 g = gasleft();
        (push, trust, , ) = _sync(user);
        _refund(msg.sender, g);
    }

    function redeemCredit(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        uint256 g = gasleft();
        ( , , int256 eff, uint256 credits) = _sync(msg.sender);
        if (credits == 0) revert NoCredit();

        uint256 ratePct = _ratePercent(eff);
        uint256 payout  = UNIT * ratePct / 100;

        if (address(this).balance < totalEarmarked + MIN_RESERVE + payout) revert PoolTooThin();

        _acct[msg.sender].credits = uint128(credits - 1);
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        emit CreditRedeemed(msg.sender, eff, ratePct, payout);

        if (payout > 0) _send(msg.sender, payout);
        _refund(msg.sender, g);
    }

    // ───────────────────────────────────────────── Views
    function offers(uint256 id) external view returns (
        address donor, address holder, uint256 principal, bool active,
        uint256 createdBlock, OfferType kind, bytes32 recordHash
    ) {
        Offer storage o = _offers[id];
        return (o.donor, o.holder, o.principal, o.active, o.createdBlock, o.kind, o.recordHash);
    }

    function lastTrust(address user) external view returns (uint256) { return _acct[user].lastTrust; }
    function redemptionCredits(address user) external view returns (uint256) { return _acct[user].credits; }

    function commonPool() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > totalEarmarked ? bal - totalEarmarked : 0;
    }

    function poolBalance() external view returns (uint256) { return address(this).balance; }

    function pendingCredits(address user) external view returns (uint256) {
        Account memory a = _acct[user];
        uint256 t = SOS.trustCountOf(user);
        return a.credits + (t > a.lastTrust ? t - a.lastTrust : 0);
    }

    function ratePercentOf(int256 eff) external pure returns (uint256) { return _ratePercent(eff); }

    function quoteRedeemCredit(address user) external view returns (uint256 ratePct, uint256 payout) {
        ratePct = _ratePercent(SOS.effectiveOf(user));
        payout  = UNIT * ratePct / 100;
    }

    function isEligible(address user) external view returns (bool) {
        Account memory a = _acct[user];
        uint256 t = SOS.trustCountOf(user);
        return a.credits + (t > a.lastTrust ? t - a.lastTrust : 0) > 0;
    }

    function signerMetrics(address user) external view returns (uint256, uint256, int256) {
        return SOS.statsOf(user);
    }

    function offerCountOf(address h) external view returns (uint256) { return offersHeldBy[h].length; }
    function offerIdsOf(address h) external view returns (uint256[] memory) { return offersHeldBy[h]; }

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // ───────────────────────────────────────────── Internal
    function _ratePercent(int256 eff) private pure returns (uint256) {
        uint256 abs = eff >= 0 ? uint256(eff) : uint256(-eff);
        uint256 pos = (abs / RATE_STEP) % CYCLE_STEPS;
        return pos == DEAD_ZONE_POS ? 0 : BASE_RATE_PCT + pos;
    }

    function _sync(address user) private returns (uint256 push, uint256 trust, int256 eff, uint256 credits) {
        (push, trust, eff) = SOS.statsOf(user);
        Account memory a = _acct[user];
        credits = a.credits;
        if (trust > a.lastTrust) {
            uint256 earned = trust - a.lastTrust;
            credits += earned;
            _acct[user] = Account(uint128(trust), uint128(credits));
            emit CreditsSynced(user, earned, credits, push, trust);
        }
    }

    function _push(address holder, uint256 id) private returns (uint64 idx) {
        idx = uint64(offersHeldBy[holder].length);
        offersHeldBy[holder].push(id);
    }

    function _pop(address holder, uint256 idx) private {
        uint256[] storage arr = offersHeldBy[holder];
        uint256 last = arr.length - 1;
        if (idx != last) {
            uint256 lastId = arr[last];
            arr[idx] = lastId;
            _offers[lastId].index = uint64(idx);
        }
        arr.pop();
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Refund measured gas from common pool. Never dips below MIN_RESERVE.
    function _refund(address to, uint256 gasStart) private {
        uint256 used = gasStart - gasleft() + GAS_OVERHEAD;
        uint256 refund = used * tx.gasprice;
        uint256 pool = commonPool();

        if (refund + MIN_RESERVE > pool) {
            refund = pool > MIN_RESERVE ? pool - MIN_RESERVE : 0;
        }
        if (refund > 0) {
            _send(to, refund);
            emit GasRefunded(to, used, refund);
        }
    }
}