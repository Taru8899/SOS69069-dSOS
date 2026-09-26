// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISOS69069
/// @notice Interface to the deployed SOS69069 ledger. That contract has no
///         transferable asset and rejects ETH; it only records signed
///         messages and exposes live Trust-Push reputation counters.
interface ISOS69069 {
    /// @notice Records a signed message from `signer` intended for `intendedTo`.
    /// @dev Reverts on exact (signer, intendedTo, payloadHash, metadata) repeat.
    function recordSignature(
        address signer,
        address intendedTo,
        bytes32 payloadHash,
        bytes calldata signature,
        string calldata metadata
    ) external;

    /// @notice Trust[user] - Push[user], computed live.
    function effectiveOf(address user) external view returns (int256);

    /// @notice Number of records where `user` was the signer.
    function pushCountOf(address user) external view returns (uint256);

    /// @notice Number of records where `user` was the intendedTo.
    function trustCountOf(address user) external view returns (uint256);
}

/// @title SOS69069 R1X1 — Ledger-Witnessed, ETH-Backed Bearer Bond Relay
/// @notice Ownerless bearer-bond mechanism. Each Bond is an ETH claim held
///         by this contract; moving a Bond requires a real signature
///         recorded on the SOS69069 ledger at SOS69069_LEDGER, gated by
///         the holder's live effectiveOf() score.
/// @dev SOS69069 tokens are not transferable on the ledger itself — R1X1's
///      Bond is the actual asset-bearing object; the ledger call is a
///      witness + eligibility check, not an asset transfer.
contract SOS69069R1X1 {

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

    /// @notice Bond.origin sentinel: redeemable at the pool itself.
    address public constant COMMON_ORIGIN = address(0);

    /// @notice Minimum SOS69069 effectiveOf() required to relay.
    int256 public constant MIN_EFFECTIVE = -69;

    /// @notice Maximum SOS69069 effectiveOf() required to relay.
    int256 public constant MAX_EFFECTIVE = 69;

    // =========================================================================
    // STATE
    // =========================================================================

    /// @notice One ETH-backed bond.
    /// @param origin address(0) for a common bond; otherwise the fixed
    ///        redemption address of a directed bond.
    /// @param holder Current holder, entitled to relay this bond.
    /// @param active False once redeemed.
    /// @param earmarked True if backed by protected (non-shared) ETH.
    struct Bond {
        address origin;
        address holder;
        bool active;
        bool earmarked;
    }

    /// @notice All bonds by id.
    mapping(uint256 => Bond) public bonds;

    /// @notice Next bond id to mint.
    uint256 public nextBondId = 1;

    /// @notice ETH locked for active directed bonds; excluded from common
    /// redemptions and MIN_RESERVE.
    uint256 public totalEarmarked;

    /// @notice Bond ids held by an address.
    mapping(address => uint256[]) public bondsHeldBy;

    /// @dev bondId => index in bondsHeldBy[holder], for O(1) removal.
    mapping(uint256 => uint256) private _holderIndex;

    // =========================================================================
    // EVENTS
    // =========================================================================

    /// @notice Common donation minted `count` bonds to `mintTo`.
    event DonatedCommon(address indexed donor, address indexed mintTo, uint256 startId, uint256 count, uint256 value);

    /// @notice Directed donation minted `count` earmarked bonds to `mintTo`, redeemable at `origin`.
    event DonatedDirected(address indexed donor, address indexed mintTo, address indexed origin, uint256 startId, uint256 count, uint256 value);

    /// @notice A bond was relayed (forwarded or redeemed).
    event Relayed(uint256 indexed bondId, address indexed from, address indexed to, int256 signerEffective, bool redeemed);

    /// @notice A bond was redeemed and destroyed.
    event Redeemed(uint256 indexed bondId, address indexed holder, address indexed redeemTarget, bool earmarked, uint256 principalPaid, uint256 gasReimbursed);

    /// @notice Plain ETH received with no bond minted.
    event Donation(address indexed from, uint256 amount);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        SOS = ISOS69069(SOS69069_LEDGER);
    }

    // =========================================================================
    // DONATIONS
    // =========================================================================

    /// @notice Accepts plain ETH top-ups; no bond minted.
    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }

    /// @notice Donates UNIT*count ETH and mints `count` common bonds to `mintTo`.
    /// @dev Redeemable by any holder at the pool, capacity-limited (see commonAvailable).
    function donateCommon(address mintTo, uint256 count) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(count > 0, "count must be > 0");
        require(msg.value == UNIT * count, "value must equal UNIT * count");

        uint256 startId = nextBondId;
        for (uint256 i = 0; i < count; i++) {
            uint256 id = nextBondId++;
            bonds[id] = Bond({origin: COMMON_ORIGIN, holder: mintTo, active: true, earmarked: false});
            _addToHolder(mintTo, id);
        }

        emit DonatedCommon(msg.sender, mintTo, startId, count, msg.value);
    }

    /// @notice Donates UNIT*count ETH and mints `count` bonds to `mintTo`,
    ///         each redeemable only at `origin` and fully earmarked.
    function donateDirected(address mintTo, address origin, uint256 count) external payable {
        require(mintTo != address(0), "mintTo is zero address");
        require(origin != address(0), "origin is zero address");
        require(count > 0, "count must be > 0");
        require(msg.value == UNIT * count, "value must equal UNIT * count");

        uint256 startId = nextBondId;
        for (uint256 i = 0; i < count; i++) {
            uint256 id = nextBondId++;
            bonds[id] = Bond({origin: origin, holder: mintTo, active: true, earmarked: true});
            _addToHolder(mintTo, id);
        }

        totalEarmarked += msg.value;

        emit DonatedDirected(msg.sender, mintTo, origin, startId, count, msg.value);
    }

    // =========================================================================
    // RELAY
    // =========================================================================

    /// @notice Relays a bond to `to`: records a signature on SOS69069_LEDGER,
    ///         then redeems (if `to` is the redeem target) or forwards the bond.
    /// @dev Requires msg.sender to hold the bond and have effectiveOf() in
    ///      [MIN_EFFECTIVE, MAX_EFFECTIVE]. Use a fresh payloadHash/metadata
    ///      per relay to avoid the ledger's duplicate-record check.
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

        int256 eff = SOS.effectiveOf(msg.sender);
        require(eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE, "effective out of range");

        SOS.recordSignature(msg.sender, to, payloadHash, signature, metadata);

        address redeemTarget = b.origin == COMMON_ORIGIN ? address(this) : b.origin;
        bool willRedeem = (to == redeemTarget);

        if (willRedeem) {
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

    /// @notice Total ETH held by this contract (earmarked + unearmarked).
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
        return b.origin == COMMON_ORIGIN ? address(this) : b.origin;
    }

    /// @notice Whether relaying `bondId` to `to` would redeem it.
    function isRedeemable(uint256 bondId, address to) external view returns (bool) {
        Bond storage b = bonds[bondId];
        if (!b.active) return false;
        address redeemTarget = b.origin == COMMON_ORIGIN ? address(this) : b.origin;
        return to == redeemTarget;
    }

    /// @notice Whether `signer`'s effectiveOf() is within the relay-eligible range.
    function isEligible(address signer) external view returns (bool) {
        int256 eff = SOS.effectiveOf(signer);
        return eff >= MIN_EFFECTIVE && eff <= MAX_EFFECTIVE;
    }

    /// @notice Live push/trust/effective values for `signer` from the ledger.
    function signerMetrics(address signer)
        external
        view
        returns (uint256 push, uint256 trust, int256 effective)
    {
        push = SOS.pushCountOf(signer);
        trust = SOS.trustCountOf(signer);
        effective = SOS.effectiveOf(signer);
    }

    /// @notice Number of active bonds held by `holder`.
    function bondCountOf(address holder) external view returns (uint256) {
        return bondsHeldBy[holder].length;
    }

    /// @notice Bond ids held by `holder`. Order not preserved across removals.
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