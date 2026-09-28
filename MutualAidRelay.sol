// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISOS69069
/// @notice External SOS69069 ledger: no transferable asset, only signed records and live Push/Trust counters.
interface ISOS69069 {
    function recordSignature(address signer, address intendedTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external;
    function recordStructHash(address signer, address intendedTo, bytes32 payloadHash, string calldata metadata) external pure returns (bytes32);
    function effectiveOf(address user) external view returns (int256);
    function pushCountOf(address user) external view returns (uint256);
    function trustCountOf(address user) external view returns (uint256);
}

/// @title SOS69069 dSOS
/// @notice Ownerless. Directed bonds are transferable bearer claims that
///         always redeem back to their original donor. The common pool is
///         donation-funded only and drawn down solely via flat, credit-gated
///         redemption. Every state-changing action is atomic with a signed
///         SOS69069 record; if the record call reverts, the whole
///         transaction reverts. All local state is finalized before any
///         external ledger call.
/// @dev Credits accrue only from increases in trustCountOf(). Push activity
///      earns nothing, so a redemption's own ledger record (which raises the
///      caller's Push, not Trust) can never mint a replacement credit.
contract dSOS {

    // ============================================================ CONSTANTS

    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public immutable SOS;

    uint256 public constant UNIT = 0.000369 ether;
    uint256 public constant MIN_RESERVE = 0.000999 ether;

    int256 public constant MIN_EFFECTIVE = -69069;
    int256 public constant MAX_EFFECTIVE = 69069;

    /// @notice Minimum lifetime pushCount + trustCount required to redeem a credit.
    uint256 public constant MIN_ACTIVITY = 1000;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // =============================================================== ERRORS

    error ZeroAddress();
    error InvalidValue();
    error BondNotActive();
    error NotHolder();
    error NoCredit();
    error EffectiveOutOfRange();
    error InsufficientActivity();
    error PoolTooThin();
    error TransferFailed();
    error Reentrant();

    // =============================================================== STATE

    struct Bond {
        address donor;
        address holder;
        uint256 principal;
        bool active;
        bytes32 creationRecordHash;
    }

    mapping(uint256 => Bond) public bonds;
    uint256 public nextBondId = 1;
    uint256 public totalEarmarked;

    mapping(address => uint256[]) public bondsHeldBy;
    mapping(uint256 => uint256) private _holderIndex;

    /// @notice Last observed trustCountOf() value per user; credits accrue from increases only.
    mapping(address => uint256) public lastTrust;
    mapping(address => uint256) public redemptionCredits;

    bool private _locked;

    // ============================================================== EVENTS

    event DonatedDirected(address indexed donor, address indexed to, uint256 indexed bondId, uint256 principal);
    event BondTransferred(uint256 indexed bondId, address indexed from, address indexed to);
    event BondRedeemed(uint256 indexed bondId, address indexed donor, address indexed holder, uint256 principal);
    event CommonDonation(address indexed donor, uint256 amount);
    event Donation(address indexed from, uint256 amount);
    event CreditsSynced(address indexed user, uint256 creditsEarned, uint256 totalCredits, uint256 pushCount, uint256 trustCount);
    event CreditRedeemed(address indexed user, int256 signerEffective, uint256 amountPaid);

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    constructor() {
        SOS = ISOS69069(SOS69069_LEDGER);
    }

    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    // ============================================================== DONATION

    function donateCommon(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        if (msg.value == 0) revert InvalidValue();
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        emit CommonDonation(msg.sender, msg.value);
    }

    // ============================================================== DIRECTED

    /// @notice Creates a directed bond for any ETH amount, atomic with a
    ///         donor -> to ledger record. State is finalized before the
    ///         external call so nothing is left pending across it.
    function donateDirected(address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidValue();

        bytes32 recordHash = SOS.recordStructHash(msg.sender, to, payloadHash, metadata);
        uint256 id = nextBondId++;
        bonds[id] = Bond(msg.sender, to, msg.value, true, recordHash);
        _addToHolder(to, id);
        totalEarmarked += msg.value;

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        emit DonatedDirected(msg.sender, to, id, msg.value);
    }

    /// @notice Transfers a bond to a new holder; only the current holder may call.
    function transferBond(uint256 bondId, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        Bond storage b = bonds[bondId];
        if (!b.active) revert BondNotActive();
        if (b.holder != msg.sender) revert NotHolder();
        if (to == address(0)) revert ZeroAddress();

        _removeFromHolder(msg.sender, bondId);
        b.holder = to;
        _addToHolder(to, bondId);

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        emit BondTransferred(bondId, msg.sender, to);
    }

    /// @notice Redeems a bond; only the current holder may call. Ledger
    ///         record always targets the original donor. Requires
    ///         effectiveOf(holder) in range.
    function redeemDirected(uint256 bondId, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        Bond storage b = bonds[bondId];
        if (!b.active) revert BondNotActive();
        if (b.holder != msg.sender) revert NotHolder();

        int256 eff = SOS.effectiveOf(msg.sender);
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) revert EffectiveOutOfRange();

        address donor = b.donor;
        address holder = msg.sender;
        uint256 principal = b.principal;

        b.active = false;
        totalEarmarked -= principal;
        _removeFromHolder(holder, bondId);

        SOS.recordSignature(holder, donor, payloadHash, signature, metadata);

        emit BondRedeemed(bondId, donor, holder, principal);

        (bool ok, ) = payable(holder).call{value: principal}("");
        if (!ok) revert TransferFailed();
    }

    // ================================================================ CREDITS

    /// @notice Adds 1 credit per new trust record since the last sync. Push
    ///         activity earns nothing. Returns the current push and trust counts.
    /// @dev No-op if trustCountOf() has not increased. Callable by anyone, anytime.
    function syncCredits(address user) public returns (uint256 currentPush, uint256 currentTrust) {
        currentPush = SOS.pushCountOf(user);
        currentTrust = SOS.trustCountOf(user);
        uint256 trustDelta = currentTrust > lastTrust[user] ? currentTrust - lastTrust[user] : 0;
        if (trustDelta == 0) return (currentPush, currentTrust);

        lastTrust[user] = currentTrust;
        redemptionCredits[user] += trustDelta;

        emit CreditsSynced(user, trustDelta, redemptionCredits[user], currentPush, currentTrust);
    }

    /// @notice Redeems 1 credit for a flat UNIT ETH from the common pool.
    /// @dev Requires >=1 credit, effectiveOf(caller) in range, lifetime
    ///      pushCount + trustCount >= MIN_ACTIVITY, and pool stays >= MIN_RESERVE after payout.
    function redeemCredit(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        (uint256 push, uint256 trust) = syncCredits(msg.sender);
        if (redemptionCredits[msg.sender] == 0) revert NoCredit();

        int256 eff = SOS.effectiveOf(msg.sender);
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) revert EffectiveOutOfRange();
        if (push + trust < MIN_ACTIVITY) revert InsufficientActivity();

        if (commonPool() < MIN_RESERVE + UNIT) revert PoolTooThin();

        redemptionCredits[msg.sender] -= 1;

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);

        emit CreditRedeemed(msg.sender, eff, UNIT);

        (bool ok, ) = payable(msg.sender).call{value: UNIT}("");
        if (!ok) revert TransferFailed();
    }

    // =================================================================VIEWS

    function commonPool() public view returns (uint256) {
        uint256 balance = address(this).balance;
        return balance > totalEarmarked ? balance - totalEarmarked : 0;
    }

    function poolBalance() external view returns (uint256) { return address(this).balance; }

    /// @notice True iff caller would currently pass every redeemCredit gate.
    function isEligible(address user) external view returns (bool) {
        int256 eff = SOS.effectiveOf(user);
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) return false;
        if (pendingCredits(user) == 0) return false;
        return SOS.pushCountOf(user) + SOS.trustCountOf(user) >= MIN_ACTIVITY;
    }

    function signerMetrics(address user) external view returns (uint256 push, uint256 trust, int256 effective) {
        push = SOS.pushCountOf(user);
        trust = SOS.trustCountOf(user);
        effective = SOS.effectiveOf(user);
    }

    /// @notice Live credit balance as of a hypothetical syncCredits call now.
    function pendingCredits(address user) public view returns (uint256) {
        uint256 currentTrust = SOS.trustCountOf(user);
        uint256 trustDelta = currentTrust > lastTrust[user] ? currentTrust - lastTrust[user] : 0;
        return redemptionCredits[user] + trustDelta;
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