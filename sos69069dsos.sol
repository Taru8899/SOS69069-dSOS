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
/// @notice Ownerless. Offers (B/T/P): non-cancellable, transferable, redeemed in
///         full by the current holder. Credits: earned from trust only, spent at
///         a sawtooth rate, transferable as clean provenance-free hops. GasClaim:
///         minimal ERC20, mints a fixed 1 wei to msg.sender per nonzero
///         receive()/donateCommon call, redeemable 1:1 for ETH. The common pool
///         grows only via receive()/donateCommon and shrinks only via
///         redeemCredit/redeemGasClaim payouts.
contract dSOS {
    // ───────────────────────────────────────────── Constants
    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public constant SOS = ISOS69069(SOS69069_LEDGER);

    uint256 public constant UNIT              = 0.006 ether;
    uint256 public constant MIN_RESERVE       = 0.000999 ether;
    uint256 public constant DEAD_ZONE_PAYOUT  = 0.0000033 ether; // ≈ $0.01
    uint256 public constant RATE_STEP         = 1001;
    uint256 public constant BASE_RATE_PCT     = 30;
    uint256 public constant CYCLE_STEPS       = 71;
    uint256 public constant DEAD_ZONE_POS     = 70;
    uint256 public constant GAS_CLAIM_MINT    = 1; // wei, fixed, per nonzero donation call

    // ───────────────────────────────────────────── Errors
    error ZeroAddress();
    error ZeroAmount();
    error InvalidValue();
    error OfferNotActive();
    error NotHolder();
    error NoCredit();
    error InsufficientCredits();
    error InsufficientBalance();
    error InsufficientAllowance();
    error PoolTooThin();
    error TransferFailed();
    error Reentrant();

    // ───────────────────────────────────────────── Storage
    enum OfferType { B, T, P }

    struct Offer {
        address holder;
        uint96  principal;
        address donor;
        bool    active;
        uint64  index;
        OfferType kind;
        bytes32 recordHash;
    }

    struct Account {
        uint256 lastTrust;
        uint256 credits;
    }

    mapping(uint256 => Offer) private _offers;
    mapping(address => Account) private _acct;
    mapping(address => uint256[]) public offersHeldBy;

    uint64  public nextOfferId = 1;
    bool    private _locked;
    uint128 public totalEarmarked;

    // GasClaim (minimal ERC20, embedded)
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    // ───────────────────────────────────────────── Events
    event OfferCreated(uint256 indexed id, OfferType kind, address indexed donor, address indexed to, uint256 principal);
    event OfferTransferred(uint256 indexed id, address indexed from, address indexed to);
    event OfferRedeemed(uint256 indexed id, address indexed donor, address indexed holder, uint256 principal);
    event CommonDonation(address indexed donor, uint256 amount);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 earned, uint256 total, uint256 push, uint256 trust);
    event CreditRedeemed(address indexed user, int256 eff, uint256 ratePct, uint256 paid);
    event CreditsTransferred(address indexed from, address indexed to, uint256 amount, int256 effAtSend, uint256 trustAtSend);
    event GasClaimRedeemed(address indexed user, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ───────────────────────────────────────────── Modifiers
    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    // ───────────────────────────────────────────── Funding
    /// @notice Plain ETH top-up. Mints GasClaim only if value > 0. No ledger record.
    receive() external payable {
        if (msg.value > 0) _mint(msg.sender, GAS_CLAIM_MINT);
        emit Donation(msg.sender, msg.value);
    }

    /// @notice Donates ETH to the pool with a donor -> ledger record. No offer minted.
    function donateCommon(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable nonReentrant {
        if (msg.value == 0) revert InvalidValue();
        _mint(msg.sender, GAS_CLAIM_MINT);
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        emit CommonDonation(msg.sender, msg.value);
    }

    // ───────────────────────────────────────────── Offers
    /// @notice Locks msg.value for `to`, atomic with a donor -> to record. Non-cancellable.
    function createOffer(
        OfferType kind,
        address to,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external payable nonReentrant {
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
            kind: kind,
            recordHash: rh
        });
        totalEarmarked += uint128(msg.value);

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);
        emit OfferCreated(id, kind, msg.sender, to, msg.value);
    }

    /// @notice Transfers an offer to a new holder. Current holder only.
    function transferOffer(uint256 id, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        Offer storage o = _offers[id];
        if (!o.active) revert OfferNotActive();
        if (o.holder != msg.sender) revert NotHolder();
        if (to == address(0)) revert ZeroAddress();

        _pop(msg.sender, o.index);
        o.index = _push(to, id);
        o.holder = to;

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);
        emit OfferTransferred(id, msg.sender, to);
    }

    /// @notice Redeems an offer. Current holder only. Record targets the original donor.
    function redeemOffer(uint256 id, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
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
    }

    // ───────────────────────────────────────────── Credits
    /// @notice Credits `user` 1 per new trust record since the last sync.
    function syncCredits(address user) external returns (uint256 push, uint256 trust) {
        (push, trust, , ) = _sync(user);
    }

    /// @notice Burns 1 credit; pays UNIT * sawtooth-rate(effectiveOf(caller)) / 100.
    function redeemCredit(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        (, , int256 eff, uint256 credits) = _sync(msg.sender);
        if (credits == 0) revert NoCredit();

        uint256 payout = _payoutFor(eff);
        if (address(this).balance < totalEarmarked + MIN_RESERVE + payout) revert PoolTooThin();

        _acct[msg.sender].credits = credits - 1;
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);

        uint256 ratePct = payout == DEAD_ZONE_PAYOUT ? 0 : (payout * 100) / UNIT;
        emit CreditRedeemed(msg.sender, eff, ratePct, payout);

        if (payout > 0) _send(msg.sender, payout);
    }

    /// @notice Moves `amount` credits to `to`, a clean hop with no stored provenance.
    function transferCredits(address to, uint256 amount, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_acct[msg.sender].credits < amount) revert InsufficientCredits();

        int256 effAtSend = SOS.effectiveOf(msg.sender);
        uint256 trustAtSend = SOS.trustCountOf(msg.sender);

        _acct[msg.sender].credits -= amount;
        _acct[to].credits += amount;

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);
        emit CreditsTransferred(msg.sender, to, amount, effAtSend, trustAtSend);
    }

    // ───────────────────────────────────────────── GasClaim (minimal ERC20)
    function gasClaimName() external pure returns (string memory) { return "GasClaim"; }
    function gasClaimSymbol() external pure returns (string memory) { return "GASC"; }
    function decimals() external pure returns (uint8) { return 18; }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Burns `amount` GasClaim; pays `amount` wei from the common pool.
    function redeemGasClaim(uint256 amount, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        if (address(this).balance < totalEarmarked + MIN_RESERVE + amount) revert PoolTooThin();

        _burn(msg.sender, amount);
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        emit GasClaimRedeemed(msg.sender, amount);
        _send(msg.sender, amount);
    }

    // ───────────────────────────────────────────── Views
    function offers(uint256 id) external view returns (
        address donor, address holder, uint256 principal, bool active,
        OfferType kind, bytes32 recordHash
    ) {
        Offer storage o = _offers[id];
        return (o.donor, o.holder, o.principal, o.active, o.kind, o.recordHash);
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

    function ratePercentOf(int256 eff) external pure returns (uint256) {
        uint256 abs = eff >= 0 ? uint256(eff) : uint256(-(eff + 1)) + 1;
        uint256 pos = (abs / RATE_STEP) % CYCLE_STEPS;
        return pos == DEAD_ZONE_POS ? 0 : BASE_RATE_PCT + pos;
    }

    function quoteRedeemCredit(address user) external view returns (uint256 ratePct, uint256 payout) {
        int256 eff = SOS.effectiveOf(user);
        payout = _payoutFor(eff);
        ratePct = payout == DEAD_ZONE_PAYOUT ? 0 : (payout * 100) / UNIT;
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
    function _payoutFor(int256 eff) private pure returns (uint256) {
        uint256 abs = eff >= 0 ? uint256(eff) : uint256(-(eff + 1)) + 1;
        uint256 pos = (abs / RATE_STEP) % CYCLE_STEPS;
        if (pos == DEAD_ZONE_POS) return DEAD_ZONE_PAYOUT;
        return UNIT * (BASE_RATE_PCT + pos) / 100;
    }

    function _sync(address user) private returns (uint256 push, uint256 trust, int256 eff, uint256 credits) {
        (push, trust, eff) = SOS.statsOf(user);
        Account memory a = _acct[user];
        credits = a.credits;
        if (trust > a.lastTrust) {
            uint256 earned = trust - a.lastTrust;
            credits += earned;
            _acct[user] = Account(trust, credits);
            emit CreditsSynced(user, earned, credits, push, trust);
        }
    }

    function _push(address holder, uint256 id) private returns (uint64 idx) {
        idx = uint64(offersHeldBy[holder].length);
        offersHeldBy[holder].push(id);
    }

    function _pop(address holder, uint256 idx) private {
        uint256[] storage arr = offersHeldBy[holder];
        if (arr.length == 0 || idx >= arr.length) revert OfferNotActive();
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

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) private {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}