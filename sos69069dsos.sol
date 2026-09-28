// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title ISOS69069
/// @notice External SOS69069 ledger: no transferable asset, only signed records and live Push/Trust counters.
interface ISOS69069 {
    function recordSignature(address signer, address intendedTo, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external;
    function recordStructHash(address signer, address intendedTo, bytes32 payloadHash, string calldata metadata) external pure returns (bytes32);
    function effectiveOf(address user) external view returns (int256);
    function trustCountOf(address user) external view returns (uint256);
    function statsOf(address user) external view returns (uint256 pushCount, uint256 trustCount, int256 effective);
}

/// @title SOS69069 dSOS
/// @notice Ownerless. Directed bonds are transferable bearer claims that always
///         redeem back to their original donor. The common pool is donation-funded
///         and drawn down only by flat, credit-gated redemption. Every state-changing
///         action is atomic with a signed SOS69069 record: if the record reverts, so
///         does the transaction. Local state is finalized before the ledger call.
/// @dev Credits accrue only from increases in trustCountOf(); push earns nothing, so a
///      redemption's own record (which raises the caller's Push) cannot mint a credit.
///      A donor may create a self-bond; a bond can never be transferred to its donor.
///      Principal is stored as uint96 and counters as uint128 to pack storage.
contract dSOS {

    // ============================================================ CONSTANTS

    address public constant SOS69069_LEDGER = 0x7373DBC24Dcd785896E8Ac3d5372c6ced9B75a8A;
    ISOS69069 public constant SOS = ISOS69069(SOS69069_LEDGER);

    uint256 public constant UNIT = 0.000369 ether;
    uint256 public constant MIN_RESERVE = 0.000999 ether;
    int256 public constant MIN_EFFECTIVE = -69069;
    int256 public constant MAX_EFFECTIVE = 69069;
    /// @notice Minimum lifetime push + trust required to redeem a credit.
    uint256 public constant MIN_ACTIVITY = 1000;

    function name() external pure returns (string memory) { return "SOS69069 dSOS"; }
    function symbol() external pure returns (string memory) { return "dSOS"; }

    // =============================================================== ERRORS

    error ZeroAddress();
    error InvalidValue();
    error BondNotActive();
    error NotHolder();
    error DonorCannotHold();
    error NoCredit();
    error EffectiveOutOfRange();
    error InsufficientActivity();
    error PoolTooThin();
    error TransferFailed();
    error Reentrant();

    // =============================================================== STORAGE

    /// @dev 3 slots: [holder, principal] [donor, active, index] [recordHash].
    ///      index = position in bondsHeldBy[holder].
    struct Bond {
        address holder;
        uint96 principal;
        address donor;
        bool active;
        uint64 index;
        bytes32 recordHash;
    }

    /// @dev 1 slot per user: last synced trust count and spendable credits.
    struct Account {
        uint128 lastTrust;
        uint128 credits;
    }

    mapping(uint256 => Bond) private _bonds;
    mapping(address => Account) private _acct;
    mapping(address => uint256[]) public bondsHeldBy;

    /// @dev Packed into one slot.
    uint64 public nextBondId = 1;
    bool private _locked;
    /// @notice ETH locked in active directed bonds; excluded from the common pool.
    uint128 public totalEarmarked;

    // =============================================================== EVENTS

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

    // ============================================================== FUNDING

    /// @notice Plain ETH top-up to the common pool; no record, no bond.
    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    /// @notice Donates ETH to the common pool with a donor -> ledger record. No bond minted.
    function donateCommon(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable {
        if (msg.value == 0) revert InvalidValue();
        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);
        emit CommonDonation(msg.sender, msg.value);
    }

    // ============================================================== DIRECTED

    /// @notice Creates a directed bond for msg.value (any nonzero amount up to uint96),
    ///         atomic with a donor -> `to` record. `to` may equal the donor.
    function donateDirected(address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external payable nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0 || msg.value > type(uint96).max) revert InvalidValue();

        bytes32 recordHash = SOS.recordStructHash(msg.sender, to, payloadHash, metadata);
        uint256 id = nextBondId++;
        _bonds[id] = Bond(to, uint96(msg.value), msg.sender, true, _push(to, id), recordHash);
        totalEarmarked += uint128(msg.value);

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        emit DonatedDirected(msg.sender, to, id, msg.value);
    }

    /// @notice Transfers a bond to a new holder; current holder only. Never to the donor.
    function transferBond(uint256 bondId, address to, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        Bond storage b = _bonds[bondId];
        if (!b.active) revert BondNotActive();
        if (b.holder != msg.sender) revert NotHolder();
        if (to == address(0)) revert ZeroAddress();
        if (to == b.donor) revert DonorCannotHold();

        _pop(msg.sender, b.index);
        b.index = _push(to, bondId);
        b.holder = to;

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        emit BondTransferred(bondId, msg.sender, to);
    }

    /// @notice Redeems a bond; current holder only, with effectiveOf(holder) in range.
    ///         The record targets the original donor; the holder receives the full principal.
    function redeemDirected(uint256 bondId, bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        Bond storage b = _bonds[bondId];
        if (!b.active) revert BondNotActive();
        if (b.holder != msg.sender) revert NotHolder();

        int256 eff = SOS.effectiveOf(msg.sender);
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) revert EffectiveOutOfRange();

        address donor = b.donor;
        uint96 principal = b.principal;

        b.active = false;
        totalEarmarked -= principal;
        _pop(msg.sender, b.index);

        SOS.recordSignature(msg.sender, donor, payloadHash, signature, metadata);

        emit BondRedeemed(bondId, donor, msg.sender, principal);

        _send(msg.sender, principal);
    }

    // ================================================================ CREDITS

    /// @notice Credits `user` 1 per new trust record since the last sync. Anyone may call.
    function syncCredits(address user) external returns (uint256 push, uint256 trust) {
        (push, trust, , ) = _sync(user);
    }

    /// @notice Redeems 1 credit for a flat UNIT from the common pool.
    /// @dev Needs >=1 credit, effectiveOf in range, push + trust >= MIN_ACTIVITY, and the
    ///      pool must remain >= MIN_RESERVE after payout. No gas reimbursement.
    function redeemCredit(bytes32 payloadHash, bytes calldata signature, string calldata metadata) external nonReentrant {
        (uint256 push, uint256 trust, int256 eff, uint256 credits) = _sync(msg.sender);
        if (credits == 0) revert NoCredit();
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE) revert EffectiveOutOfRange();
        if (push + trust < MIN_ACTIVITY) revert InsufficientActivity();
        if (address(this).balance < totalEarmarked + MIN_RESERVE + UNIT) revert PoolTooThin();

        _acct[msg.sender].credits = uint128(credits - 1);

        SOS.recordSignature(msg.sender, SOS69069_LEDGER, payloadHash, signature, metadata);

        emit CreditRedeemed(msg.sender, eff, UNIT);

        _send(msg.sender, UNIT);
    }

    // =================================================================VIEWS

    function bonds(uint256 bondId) external view returns (address donor, address holder, uint256 principal, bool active, bytes32 creationRecordHash) {
        Bond storage b = _bonds[bondId];
        return (b.donor, b.holder, b.principal, b.active, b.recordHash);
    }

    function lastTrust(address user) external view returns (uint256) { return _acct[user].lastTrust; }
    function redemptionCredits(address user) external view returns (uint256) { return _acct[user].credits; }

    /// @notice Contract balance minus ETH locked in directed bonds.
    function commonPool() external view returns (uint256) {
        uint256 balance = address(this).balance;
        return balance > totalEarmarked ? balance - totalEarmarked : 0;
    }

    function poolBalance() external view returns (uint256) { return address(this).balance; }

    /// @notice Live credit balance as of a hypothetical sync now.
    function pendingCredits(address user) external view returns (uint256) {
        Account memory a = _acct[user];
        uint256 trust = SOS.trustCountOf(user);
        return a.credits + (trust > a.lastTrust ? trust - a.lastTrust : 0);
    }

    /// @notice True iff `user` passes every redeemCredit gate except pool balance.
    function isEligible(address user) external view returns (bool) {
        (uint256 push, uint256 trust, int256 eff) = SOS.statsOf(user);
        if (eff < MIN_EFFECTIVE || eff > MAX_EFFECTIVE || push + trust < MIN_ACTIVITY) return false;
        Account memory a = _acct[user];
        return a.credits + (trust > a.lastTrust ? trust - a.lastTrust : 0) > 0;
    }

    /// @notice Raw push, trust, and effective values from the ledger.
    function signerMetrics(address user) external view returns (uint256 push, uint256 trust, int256 effective) {
        return SOS.statsOf(user);
    }

    function bondCountOf(address holder) external view returns (uint256) { return bondsHeldBy[holder].length; }
    function bondIdsOf(address holder) external view returns (uint256[] memory) { return bondsHeldBy[holder]; }

    // ============================================================== INTERNAL

    /// @dev One ledger read; credits any trust increase and returns fresh stats.
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

    function _push(address holder, uint256 bondId) private returns (uint64 idx) {
        uint256[] storage arr = bondsHeldBy[holder];
        idx = uint64(arr.length);
        arr.push(bondId);
    }

    /// @dev Swap-and-pop; repoints the moved bond's stored index.
    function _pop(address holder, uint256 idx) private {
        uint256[] storage arr = bondsHeldBy[holder];
        uint256 last = arr.length - 1;
        if (idx != last) {
            uint256 lastId = arr[last];
            arr[idx] = lastId;
            _bonds[lastId].index = uint64(idx);
        }
        arr.pop();
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}