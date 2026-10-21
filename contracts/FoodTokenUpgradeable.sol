// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IFoodToken.sol";
import "./interfaces/IRolesRegistry.sol";
import "./NilaCertRegistry.sol";

interface INilaLandTitle {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getCommitment(uint256 tokenId) external view returns (bytes32);
}

/// @title FoodTokenUpgradeable
/// @notice ERC1155 crop passport — the tokenId IS the crop codex.
///
/// ══════════════════════════════════════════════════════════════════
///  TOKEN ID LAYOUT  (256 bits, big-endian)
///
///  [255:224]  landTitleId    32 bits  — NilaLandTitle NFT id
///  [223:204]  cropCode       20 bits  — 6-digit codex: cropFamily*1000 + variety (0–999999)
///  [203:172]  sosTs          32 bits  — FULL unix ts of planting (self-describing, never changes)
///  [171:148]  areaM2         24 bits  — total area across selected fields (max 16.7 M m²)
///  [147: 20]  fieldsBitmask 128 bits  — bit i = field i claimed (bit 0 = entire property)
///  [ 19:  0]  reserved       20 bits  — future dimensions
///
///  Codex display: "002 001 · 1757808000 · 005836 · 0b1000000"
///                  (crop=Sugarcane variety=COC 24, planted 2025-09-14, 5836 m², zone z6)
///  Anyone who knows this layout can decode the token without any contract call —
///  including the exact planting date, not just the year.
/// ══════════════════════════════════════════════════════════════════
///
///  SOS (planting date) is encoded IN the tokenId. Only mutable post-mint state
///  lives in thin mappings keyed by tokenId:
///    tokenHarvestTs  — EOS: estimated → actual harvest date (oracle updates)
///    tokenStatus     — 0=unminted 1=active 2=verified 3=harvested 4=cancelled
///    tokenBatch      — batch association (for claimedQtyKg tally)
///
///  ERC1155 balanceOf(farmer, tokenId) = quantity in kg.
///  Oracle adjusts via mint/burn delta — no separate committedQtyKg stored.
///
contract FoodTokenUpgradeable is
    ERC1155Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ================================================================
    //  CONDITION BITMASKS
    // ================================================================

    uint256 public constant COND_LAND_TITLE = 1 << 0;
    uint256 public constant COND_CROP_TYPE  = 1 << 1;
    /// A crop plan covers three seasons: a mint may be up to a year ahead of its SOS (P1).
    uint32  public constant MAX_SOS_AHEAD   = 366 days;
    /// A field whose token has no usable harvest date is held until the oracle reports
    /// the harvest (updateTokenHarvest / confirmHarvest). No time-based release.
    uint32  public constant HELD_UNTIL_REPORTED = type(uint32).max;

    // ================================================================
    //  STRUCTS
    // ================================================================

    /// @notice A crop programme — standing (union) or buyer-backed order.
    ///         cropCode + varietyCode form the hierarchical crop identifier.
    ///         varietyCode = 0 means "any variety accepted" at batch level.
    struct Batch {
        address union_;
        uint16  cropCode;
        uint16  varietyCode;
        bool    active;
        uint256 conditions;
        address buyer;
        uint256 targetQtyKg;
        uint256 claimedQtyKg;
        uint32  deliveryDate;
        uint256 pricePerKgUsdt;
        uint8   status;         // 0=open 1=filled 2=fulfilled 3=cancelled
        uint8   requiredCerts;
    }

    enum MemberStatus { None, Joined, Certified }

    struct BatchMember {
        MemberStatus status;
        uint8 certsAtJoin;
        uint8 certsNow;
    }

    // ================================================================
    //  STORAGE
    // ================================================================

    mapping(uint256 => Batch)   public batches;
    uint256                     public nextBatchId;

    mapping(uint16 => uint256)  public canonicalBatch;
    mapping(uint16 => string)   public cropName;
    mapping(uint16 => string[]) public varieties;

    mapping(address => bool)    public oracleSigners;
    IRolesRegistry              public rolesRegistry;
    NilaCertRegistry            public certRegistry;
    INilaLandTitle              public landTitleContract;
    uint16                      public collateralBps;

    mapping(uint256 => mapping(address => BatchMember)) public batchMembers;

    // ── per-token mutable state — packed into ONE slot ───────────────
    //   [0:7]   status   uint8   0=unminted 1=active 2=verified 3=harvested 4=cancelled
    //   [8:39]  eosTs    uint32  EOS / harvest date (oracle-set, unknown at mint)
    //   [40:103] batchId  uint64  batch association (for claimedQtyKg tally)
    // SOS (planting ts) is NOT here — it is packed into the tokenId itself.
    mapping(uint256 => uint256) internal _tokenMeta;

    // ── field exclusivity ────────────────────────────────────────────
    // Per (landTitleId, sosYear): bit N set → field N has an active token this season.
    // Bit 0 = entire property; bits 1–127 = individual fields/zones.
    // sosYear rotation means next season is always a fresh bitmask slot.
    mapping(uint32 => mapping(uint16 => uint128)) public yearFieldBitmask;

    // ── discovery index ──────────────────────────────────────────────
    mapping(uint32 => uint256[]) public landTitleTokens;

    // ── field claims per season (P1, 15 Oct 2026; appended — storage layout) ──
    // A field holds one crop at a time: a mint may start on a field from the
    // harvest date of the token that holds it. Replaces the calendar-year
    // bitmask above (kept for legacy tokens only), so one zone can carry a
    // token in every season of a 3-season crop plan.
    // title => field bit (0 = entire property, 1–127 = zones) => busy until (unix ts)
    mapping(uint32 => mapping(uint8 => uint32)) public fieldBusyUntil;

    // ── leader mints (P2, 21 Oct 2026; appended — storage layout) ──
    // The unions whose leaders may mint a member's crop share into a standing batch (union_ = 0, one per crop,
    // made by setCropType). A batch of a union's own (union_ != 0) needs no entry: its leaders may always mint.
    mapping(address => bool) public leaderMintUnions;

    // ================================================================
    //  EVENTS
    // ================================================================

    event LeaderMintUnionSet(address indexed union_, bool on);
    event CropShareMintedByLeader(uint256 indexed tokenId, address indexed union_, address indexed leader, address farmer);
    event BatchCreated(uint256 indexed batchId, address indexed union_, uint16 indexed cropCode, uint16 varietyCode, address buyer);
    event BatchArchived(uint256 indexed batchId);
    event BatchStatusUpdated(uint256 indexed batchId, uint8 status);
    event BatchPriceSet(uint256 indexed batchId, uint256 pricePerKgUsdt);

    event TokenMinted(uint256 indexed tokenId, address indexed to, uint256 indexed batchId, uint32 sosDate, uint256 initialQtyKg);
    event TokenStatusUpdated(uint256 indexed tokenId, uint8 status);
    event TokenHarvestUpdated(uint256 indexed tokenId, uint32 harvestTs);
    event TokenQtyAdjusted(uint256 indexed tokenId, uint256 oldQty, uint256 newQty);
    event HarvestConfirmed(uint256 indexed tokenId, uint32 actualHarvestTs, uint256 actualQtyKg);

    event OracleSignerSet(address indexed signer, bool allowed);
    event CropTypeSet(uint16 indexed cropCode, string name);
    event MemberJoined(uint256 indexed batchId, address indexed farmer, uint8 certsHeld, bool fullyCertified);
    event MemberCertified(uint256 indexed batchId, address indexed farmer);
    event MemberDecertified(uint256 indexed batchId, address indexed farmer);
    event CertRegistrySet(address registry);
    event TokensSold(uint256 indexed openBatchId, uint256 indexed soldBatchId, uint256[] tokenIds, uint256 qtyKg);

    // ================================================================
    //  ERRORS
    // ================================================================

    error NotOracle();
    error NotAuthorized();
    error ZeroAddress();
    error BatchNotActive();
    error EntirePropertyClaimed();
    error FieldAlreadyClaimed();
    error TokenNotFound();
    error AlreadyMember();
    error NotMember();
    error NotCertified();
    error NotLandOwner();
    error NoOracleRecord();
    error AlreadyHarvested();
    error FieldsRequired();
    error MixedEntireAndSpecific();
    error InvalidSosDate();
    error InvalidCropCode();
    error NotBurnable();
    error SosTooFar();
    error NotStanding();
    error TokenNotInBatch();
    error NotLeaderOfBatch();

    // ================================================================
    //  MODIFIERS
    // ================================================================

    modifier onlyOracle() {
        if (!oracleSigners[msg.sender]) revert NotOracle();
        _;
    }

    function _isUnionAuth(address union_) internal view returns (bool) {
        if (msg.sender == owner() || msg.sender == union_) return true;
        return address(rolesRegistry) != address(0) && rolesRegistry.isLeader(union_, msg.sender);
    }

    // ================================================================
    //  TOKEN ID CODEC
    // ================================================================

    /// @param cropCode Combined 6-digit crop codex: cropFamily*1000 + variety (0–999999).
    ///                 e.g. Sugarcane(2) / COC 24(1) → 2001 → displays "002001".
    function packTokenId(
        uint32  landTitleId,
        uint32  cropCode,
        uint32  sosTs,
        uint32  areaM2,
        uint128 fieldsBitmask
    ) public pure returns (uint256) {
        return
            (uint256(landTitleId)   << 224) |
            (uint256(cropCode)      << 204) |
            (uint256(sosTs)         << 172) |
            (uint256(areaM2)        << 148) |
            (uint256(fieldsBitmask) <<  20);
    }

    function unpackTokenId(uint256 tokenId) public pure returns (
        uint32  landTitleId,
        uint32  cropCode,
        uint32  sosTs,
        uint32  areaM2,
        uint128 fieldsBitmask
    ) {
        landTitleId   = uint32(tokenId >> 224);
        cropCode      = uint32((tokenId >> 204) & 0xFFFFF);              // 20-bit combined crop+variety
        sosTs         = uint32(tokenId >> 172);                          // full 32-bit unix ts
        areaM2        = uint32((tokenId >> 148) & 0xFFFFFF);
        fieldsBitmask = uint128((tokenId >> 20) & ((uint256(1) << 128) - 1));
    }

    // ── packed per-token meta accessors (_tokenMeta) ─────────────────
    // Public getters keep the original ABI (tokenStatus / tokenHarvestTs / tokenBatch).

    function tokenStatus(uint256 tokenId) public view returns (uint8) {
        return uint8(_tokenMeta[tokenId]);
    }

    function tokenHarvestTs(uint256 tokenId) public view returns (uint32) {
        return uint32(_tokenMeta[tokenId] >> 8);
    }

    function tokenBatch(uint256 tokenId) public view returns (uint256) {
        return uint256(uint64(_tokenMeta[tokenId] >> 40));
    }

    function _setStatus(uint256 tokenId, uint8 status_) internal {
        _tokenMeta[tokenId] = (_tokenMeta[tokenId] & ~uint256(0xFF)) | uint256(status_);
    }

    function _setEos(uint256 tokenId, uint32 eosTs) internal {
        // A burned token holds no field any more: its dates move nothing.
        if (tokenStatus(tokenId) != 4) _moveFieldBusy(tokenId, _heldUntil(tokenId), eosTs);
        _tokenMeta[tokenId] =
            (_tokenMeta[tokenId] & ~(uint256(0xFFFFFFFF) << 8)) | (uint256(eosTs) << 8);
    }

    /// @dev Reopen an auto-closed batch when freed quota should be re-mintable.
    function _maybeReopenBatch(uint256 batchId) internal {
        Batch storage b = batches[batchId];
        if (b.status == 1 && b.buyer != address(0) && b.claimedQtyKg < b.targetQtyKg) {
            b.status = 0;
            emit BatchStatusUpdated(batchId, 0);
        }
    }

    function _holderOf(uint256 tokenId) internal view returns (address) {
        return landTitleContract.ownerOf(uint32(tokenId >> 224));
    }

    // ================================================================
    //  INITIALISER
    // ================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string  calldata uri_,
        address initialOwner_,
        address initialOracle_
    ) external initializer {
        __ERC1155_init(uri_);
        __Ownable_init(initialOwner_);
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (initialOracle_ == address(0)) revert ZeroAddress();
        oracleSigners[initialOracle_] = true;
        emit OracleSignerSet(initialOracle_, true);
        collateralBps = 2000;
    }

    // ================================================================
    //  BATCH MANAGEMENT
    // ================================================================

    function createBatch(
        address union_,
        uint16  cropCode,
        uint16  varietyCode,
        address buyer,
        uint256 targetQtyKg,
        uint32  deliveryDate,
        uint256 pricePerKgUsdt,
        uint256 conditions,
        uint8   requiredCerts
    ) external returns (uint256 batchId) {
        if (!_isUnionAuth(union_)) revert NotAuthorized();
        batchId = ++nextBatchId;
        batches[batchId] = Batch({
            union_:         union_,
            cropCode:       cropCode,
            varietyCode:    varietyCode,
            active:         true,
            conditions:     conditions,
            buyer:          buyer,
            targetQtyKg:    targetQtyKg,
            claimedQtyKg:   0,
            deliveryDate:   deliveryDate,
            pricePerKgUsdt: pricePerKgUsdt,
            status:         0,
            requiredCerts:  requiredCerts
        });
        emit BatchCreated(batchId, union_, cropCode, varietyCode, buyer);
    }

    function setBatchOrder(
        uint256 batchId,
        address buyer,
        uint256 targetQtyKg,
        uint32  deliveryDate,
        uint256 pricePerKgUsdt
    ) external {
        if (buyer == address(0)) revert ZeroAddress();
        Batch storage b = batches[batchId];
        if (!_isUnionAuth(b.union_)) revert NotAuthorized();
        if (!b.active || b.status != 0) revert BatchNotActive();
        b.buyer = buyer; b.targetQtyKg = targetQtyKg;
        b.deliveryDate = deliveryDate; b.pricePerKgUsdt = pricePerKgUsdt;
        emit BatchCreated(batchId, b.union_, b.cropCode, b.varietyCode, buyer);
    }

    function archiveBatch(uint256 batchId) external {
        Batch storage b = batches[batchId];
        if (!_isUnionAuth(b.union_)) revert NotAuthorized();
        b.active = false;
        emit BatchArchived(batchId);
    }

    function setBatchPrice(uint256 batchId, uint256 pricePerKgUsdt_) external {
        Batch storage b = batches[batchId];
        if (!_isUnionAuth(b.union_) && msg.sender != b.buyer) revert NotAuthorized();
        if (!b.active || b.status != 0) revert BatchNotActive();
        b.pricePerKgUsdt = pricePerKgUsdt_;
        emit BatchPriceSet(batchId, pricePerKgUsdt_);
    }

    function updateBatchStatus(uint256 batchId, uint8 status) external {
        if (!oracleSigners[msg.sender] && msg.sender != owner()) revert NotOracle();
        batches[batchId].status = status;
        emit BatchStatusUpdated(batchId, status);
    }

    // ================================================================
    //  CERT MEMBERSHIP
    // ================================================================

    function joinBatch(uint256 batchId) external whenNotPaused {
        _join(batchId, msg.sender);
    }

    function _join(uint256 batchId, address farmer) internal {
        Batch storage b = batches[batchId];
        if (!b.active || b.status >= 1) revert BatchNotActive();
        BatchMember storage m = batchMembers[batchId][farmer];
        if (m.status != MemberStatus.None) revert AlreadyMember();

        uint8 held; bool ok;
        if (address(certRegistry) != address(0) && b.requiredCerts > 0) {
            uint8 missing;
            (held, missing, ok) = certRegistry.checkCerts(farmer, b.requiredCerts);
        } else {
            ok = true;
        }

        m.certsAtJoin = held; m.certsNow = held;
        m.status = ok ? MemberStatus.Certified : MemberStatus.Joined;
        emit MemberJoined(batchId, farmer, held, ok);
    }

    function refreshCertStatus(uint256 batchId, address farmer) external {
        Batch storage b = batches[batchId];
        BatchMember storage m = batchMembers[batchId][farmer];
        if (m.status == MemberStatus.None) revert NotMember();

        uint8 held; bool ok;
        if (address(certRegistry) != address(0) && b.requiredCerts > 0) {
            uint8 missing;
            (held, missing, ok) = certRegistry.checkCerts(farmer, b.requiredCerts);
        } else {
            ok = true; held = m.certsNow;
        }

        m.certsNow = held;
        if (ok && m.status == MemberStatus.Joined) {
            m.status = MemberStatus.Certified; emit MemberCertified(batchId, farmer);
        } else if (!ok && m.status == MemberStatus.Certified) {
            m.status = MemberStatus.Joined; emit MemberDecertified(batchId, farmer);
        }
    }

    // ================================================================
    //  MINTING
    // ================================================================

    function setLandTitleContract(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        landTitleContract = INilaLandTitle(addr);
    }

    /// @notice Mint a crop passport. The tokenId encodes the complete crop codex.
    ///
    ///  Gates:
    ///   1. Caller is a Certified batch member.
    ///   2. Caller owns the land title NFT.
    ///   3. Oracle has published a record for this field (commitment != 0).
    ///   4. Field exclusivity via per-season bitmask.
    ///
    /// @param fieldsBitmask Bit 0 = entire property (must be the only bit set when used).
    ///                      Bits 1–127 = specific cluster ids; any combination is allowed.
    function mintForBatchMember(
        uint256 batchId,
        uint32  landTitleId,
        uint32  harvestDate,
        uint256 quantity,
        uint128 fieldsBitmask,
        uint32  areaM2,
        uint16  farmerVarietyCode,
        uint32  sosDate
    ) external whenNotPaused {
        if (address(landTitleContract) == address(0)) revert ZeroAddress();
        _mintFor(msg.sender, batchId, landTitleId, harvestDate, quantity, fieldsBitmask, areaM2, farmerVarietyCode, sosDate);
    }

    /// @notice P2 (executive decision 21 Oct 2026): a leader of her union mints her crop share when approving her
    ///         crop plan. The token goes to the land title's holder (her wallet), never to the caller; she is joined
    ///         to the batch on the way if she is not a member yet (same cert check as joinBatch). Every other check
    ///         of mintForBatchMember applies unchanged. The batch is the union's own (union_ == union) or a standing
    ///         batch (union_ == 0) of a union the owner enabled with setLeaderMintUnion.
    function mintForBatchMemberByLeader(
        address union,
        uint256 batchId,
        uint32  landTitleId,
        uint32  harvestDate,
        uint256 quantity,
        uint128 fieldsBitmask,
        uint32  areaM2,
        uint16  farmerVarietyCode,
        uint32  sosDate
    ) external whenNotPaused {
        if (address(landTitleContract) == address(0)) revert ZeroAddress();
        address bu = batches[batchId].union_;
        if (union == address(0) || !(bu == union || (bu == address(0) && leaderMintUnions[union]))) revert NotLeaderOfBatch();
        if (!_isUnionAuth(union)) revert NotAuthorized();
        address farmer = landTitleContract.ownerOf(landTitleId);
        if (batchMembers[batchId][farmer].status == MemberStatus.None) _join(batchId, farmer);
        uint256 tokenId = _mintFor(farmer, batchId, landTitleId, harvestDate, quantity, fieldsBitmask, areaM2, farmerVarietyCode, sosDate);
        emit CropShareMintedByLeader(tokenId, union, msg.sender, farmer);
    }

    /// @notice Owner: let this union's leaders mint into the standing (union-less) batches.
    function setLeaderMintUnion(address union, bool on) external onlyOwner {
        if (union == address(0)) revert ZeroAddress();
        leaderMintUnions[union] = on;
        emit LeaderMintUnionSet(union, on);
    }

    function _mintFor(
        address farmer,
        uint256 batchId,
        uint32  landTitleId,
        uint32  harvestDate,
        uint256 quantity,
        uint128 fieldsBitmask,
        uint32  areaM2,
        uint16  farmerVarietyCode,
        uint32  sosDate
    ) internal returns (uint256 tokenId) {
        if (fieldsBitmask == 0) revert FieldsRequired();
        // Bit 0 ("entire property") is exclusive — can't be combined with specific fields
        if ((fieldsBitmask & 1) != 0 && fieldsBitmask != 1) revert MixedEntireAndSpecific();
        if (sosDate == 0) revert InvalidSosDate();
        if (sosDate > uint32(block.timestamp) + MAX_SOS_AHEAD) revert SosTooFar();

        BatchMember storage m = batchMembers[batchId][farmer];
        if (m.status != MemberStatus.Certified) revert NotCertified();

        if (landTitleContract.ownerOf(landTitleId) != farmer) revert NotLandOwner();
        if (landTitleContract.getCommitment(landTitleId) == bytes32(0)) revert NoOracleRecord();

        Batch storage b = batches[batchId];
        if (!b.active || b.status >= 1) revert BatchNotActive();
        // Batch varietyCode=0 means "any variety accepted"; otherwise farmer must match
        if (b.varietyCode != 0 && farmerVarietyCode != b.varietyCode) revert NotAuthorized();
        // Crop family and variety are each 3-digit (0–999) to fit the 6-digit codex
        if (b.cropCode > 999 || farmerVarietyCode > 999) revert InvalidCropCode();

        // A field is free from the harvest date of the token that holds it (P1).
        if (fieldsBitmask == 1) {
            // The entire property: every field must be free.
            for (uint8 i = 0; i < 128; i++) {
                if (sosDate < fieldBusyUntil[landTitleId][i]) revert FieldAlreadyClaimed();
            }
        } else {
            if (sosDate < fieldBusyUntil[landTitleId][0]) revert EntirePropertyClaimed();
            for (uint8 i = 1; i < 128; i++) {
                if ((fieldsBitmask >> i) & 1 == 1 && sosDate < fieldBusyUntil[landTitleId][i])
                    revert FieldAlreadyClaimed();
            }
        }

        // Combined 6-digit crop codex: cropFamily*1000 + variety. SOS is packed into the
        // tokenId itself (no separate mapping); the id is fully self-describing.
        uint32 combinedCrop = uint32(b.cropCode) * 1000 + uint32(farmerVarietyCode);
        tokenId = packTokenId(landTitleId, combinedCrop, sosDate, areaM2, fieldsBitmask);

        _mint(farmer, tokenId, quantity, "");

        // One SSTORE for all mutable per-token state: status=1, eos=harvestDate, batchId
        _tokenMeta[tokenId] =
            uint256(1) | (uint256(harvestDate) << 8) | (uint256(uint64(batchId)) << 40);

        // The live app may send no harvest date (0) or one from the previous cycle: the
        // field is then held until the oracle reports the harvest.
        _claimFields(landTitleId, fieldsBitmask,
            harvestDate > sosDate ? harvestDate : HELD_UNTIL_REPORTED);
        landTitleTokens[landTitleId].push(tokenId);

        b.claimedQtyKg += quantity;
        if (b.buyer != address(0) && b.targetQtyKg > 0 && b.claimedQtyKg >= b.targetQtyKg) {
            b.status = 1;
            emit BatchStatusUpdated(batchId, 1);
        }

        emit TokenMinted(tokenId, farmer, batchId, sosDate, quantity);
    }

    // ================================================================
    //  ORACLE UPDATES
    // ================================================================

    function updateTokenStatus(uint256 tokenId, uint8 status) external onlyOracle {
        if (tokenStatus(tokenId) == 0) revert TokenNotFound();
        _setStatus(tokenId, status);
        emit TokenStatusUpdated(tokenId, status);
    }

    function updateTokenHarvest(uint256 tokenId, uint32 harvestTs) external onlyOracle {
        if (tokenStatus(tokenId) == 0) revert TokenNotFound();
        _setEos(tokenId, harvestTs);
        emit TokenHarvestUpdated(tokenId, harvestTs);
    }

    /// @notice Oracle revises qty — mints or burns delta, keeps batch tally consistent.
    function adjustTokenQty(uint256 tokenId, uint256 newQtyKg) external onlyOracle {
        if (tokenStatus(tokenId) == 0) revert TokenNotFound();
        address holder = _holderOf(tokenId);
        uint256 oldQty = balanceOf(holder, tokenId);
        if (newQtyKg == oldQty) return;

        uint256 bId = tokenBatch(tokenId);
        Batch storage b = batches[bId];
        if (newQtyKg > oldQty) {
            _mint(holder, tokenId, newQtyKg - oldQty, "");
            b.claimedQtyKg += newQtyKg - oldQty;
        } else {
            uint256 delta = oldQty - newQtyKg;
            _burn(holder, tokenId, delta);
            b.claimedQtyKg = b.claimedQtyKg > delta ? b.claimedQtyKg - delta : 0;
            _maybeReopenBatch(bId);
        }

        emit TokenQtyAdjusted(tokenId, oldQty, newQtyKg);
    }

    /// @notice Oracle confirms harvest: sets status=3, refines harvest date, adjusts qty — atomically.
    ///         Pass actualQtyKg=0 to keep balance unchanged.
    ///         One call per token — scales trivially since EOS is a satellite event, not a user action.
    function confirmHarvest(
        uint256 tokenId,
        uint32  actualHarvestTs,
        uint256 actualQtyKg
    ) external onlyOracle {
        uint8 st = tokenStatus(tokenId);
        if (st == 0) revert TokenNotFound();
        if (st == 3) revert AlreadyHarvested();

        _setStatus(tokenId, 3);
        if (actualHarvestTs > 0) _setEos(tokenId, actualHarvestTs);

        address holder = _holderOf(tokenId);
        uint256 oldQty = balanceOf(holder, tokenId);

        if (actualQtyKg > 0 && actualQtyKg != oldQty) {
            uint256 bId = tokenBatch(tokenId);
            Batch storage b = batches[bId];
            if (actualQtyKg > oldQty) {
                _mint(holder, tokenId, actualQtyKg - oldQty, "");
                b.claimedQtyKg += actualQtyKg - oldQty;
            } else {
                uint256 delta = oldQty - actualQtyKg;
                _burn(holder, tokenId, delta);
                b.claimedQtyKg = b.claimedQtyKg > delta ? b.claimedQtyKg - delta : 0;
                _maybeReopenBatch(bId);
            }
        }

        emit HarvestConfirmed(tokenId, tokenHarvestTs(tokenId), actualQtyKg > 0 ? actualQtyKg : oldQty);
    }

    /// @notice Oracle cancels a token (dispute / fraud).
    ///         Burns the ERC1155 balance, sets status=4, clears the field bit for same-season remint.
    function burnToken(uint256 tokenId) external onlyOracle {
        if (tokenStatus(tokenId) == 0) revert TokenNotFound();
        _burnAndFreeFields(tokenId);
    }

    /// @notice Owner-callable burn: the land-title owner cancels their own ACTIVE token,
    ///         freeing its field bit for a same-season re-mint. Kept permissionless
    ///         (no oracle) so a farmer can correct/reshuffle their own fields.
    ///         Restricted to status==1: once the oracle verifies (2) or harvest is
    ///         confirmed (3), the claim is settled and can only be torn down via burnToken.
    function burnOwnToken(uint256 tokenId) external whenNotPaused {
        if (_holderOf(tokenId) != msg.sender) revert NotLandOwner();
        if (tokenStatus(tokenId) != 1) revert NotBurnable();
        _burnAndFreeFields(tokenId);
    }

    /// @dev Shared teardown: burn balance, mark cancelled, reopen batch, clear field bit.
    function _burnAndFreeFields(uint256 tokenId) internal {
        uint256 bId    = tokenBatch(tokenId);
        address holder = _holderOf(tokenId);
        uint256 qty    = balanceOf(holder, tokenId);
        if (qty > 0) {
            Batch storage b = batches[bId];
            b.claimedQtyKg = b.claimedQtyKg > qty ? b.claimedQtyKg - qty : 0;
            _burn(holder, tokenId, qty);
        }
        _setStatus(tokenId, 4);
        // Freed quota: reopen the batch so a corrected token can take this slot again
        _maybeReopenBatch(bId);

        // Clear all field bits so a corrected remint is allowed in the same season
        uint32  landTitleId   = uint32(tokenId >> 224);
        uint32  sosTs         = uint32(tokenId >> 172);
        uint16  year          = uint16(1970 + sosTs / 31_557_600);
        uint128 fieldsBitmask = uint128((tokenId >> 20) & ((uint256(1) << 128) - 1));
        yearFieldBitmask[landTitleId][year] &= ~fieldsBitmask;
        _moveFieldBusy(tokenId, _heldUntil(tokenId), sosTs);

        emit TokenStatusUpdated(tokenId, 4);
    }

    /// @notice Escape hatch: manually reopen an auto-closed batch (e.g. to extend quota
    ///         or after an out-of-band quota change). Burns already auto-reopen via burnToken.
    function reopenBatch(uint256 batchId) external onlyOracle {
        _maybeReopenBatch(batchId);
    }

    // ================================================================
    //  CROP TYPE MANAGEMENT
    // ================================================================

    function setCropType(
        uint16           cropCode,
        string  calldata name,
        string[] calldata vars
    ) external onlyOwner {
        cropName[cropCode] = name;
        varieties[cropCode] = vars;
        emit CropTypeSet(cropCode, name);

        if (canonicalBatch[cropCode] == 0) {
            uint256 batchId = ++nextBatchId;
            batches[batchId] = Batch({
                union_: address(0), cropCode: cropCode, varietyCode: 0,
                active: true, conditions: COND_LAND_TITLE | COND_CROP_TYPE,
                buyer: address(0), targetQtyKg: 0, claimedQtyKg: 0,
                deliveryDate: 0, pricePerKgUsdt: 0, status: 0, requiredCerts: 0
            });
            canonicalBatch[cropCode] = batchId;
            emit BatchCreated(batchId, address(0), cropCode, 0, address(0));
        }
    }

    function addVariety(uint16 cropCode, string calldata variety) external onlyOwner {
        varieties[cropCode].push(variety);
    }

    // ================================================================
    //  ORACLE SIGNER MANAGEMENT
    // ================================================================

    function setOracleSigner(address signer, bool allowed) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        oracleSigners[signer] = allowed;
        emit OracleSignerSet(signer, allowed);
    }

    function setRolesRegistry(address registry) external onlyOwner {
        rolesRegistry = IRolesRegistry(registry);
    }

    function setCertRegistry(address registry) external onlyOwner {
        certRegistry = NilaCertRegistry(registry);
        emit CertRegistrySet(registry);
    }

    function setCollateralBps(uint16 bps) external onlyOwner {
        require(bps <= 10000, "exceeds 100%");
        collateralBps = bps;
    }

    // ================================================================
    //  FIELD CLAIMS PER SEASON (P1)
    // ================================================================

    /// @dev The date the token's claim holds its fields until (see the mint).
    function _heldUntil(uint256 tokenId) internal view returns (uint32) {
        uint32 eos = tokenHarvestTs(tokenId);
        uint32 sos = uint32(tokenId >> 172);
        return eos > sos ? eos : HELD_UNTIL_REPORTED;
    }

    function _claimFields(uint32 landTitleId, uint128 fieldsBitmask, uint32 busyUntil) internal {
        for (uint8 i = 0; i < 128; i++) {
            if ((fieldsBitmask >> i) & 1 == 1 && fieldBusyUntil[landTitleId][i] < busyUntil)
                fieldBusyUntil[landTitleId][i] = busyUntil;
        }
    }

    /// @dev The token's harvest date moved (oracle) or it was burned: a field it still
    ///      holds is busy until `toTs` instead. A field a later token holds is left alone.
    function _moveFieldBusy(uint256 tokenId, uint32 fromTs, uint32 toTs) internal {
        if (fromTs == toTs) return;
        uint32  landTitleId   = uint32(tokenId >> 224);
        uint128 fieldsBitmask = uint128((tokenId >> 20) & ((uint256(1) << 128) - 1));
        for (uint8 i = 0; i < 128; i++) {
            if ((fieldsBitmask >> i) & 1 == 1 && fieldBusyUntil[landTitleId][i] == fromTs)
                fieldBusyUntil[landTitleId][i] = toTs;
        }
    }

    /// @notice One-off after the P1 upgrade: claim the fields of tokens minted under the
    ///         calendar-year rule, so a new season cannot overlap them. Idempotent.
    function syncFieldClaims(uint256[] calldata tokenIds) external {
        if (!oracleSigners[msg.sender] && msg.sender != owner()) revert NotOracle();
        for (uint256 k = 0; k < tokenIds.length; k++) {
            uint256 id = tokenIds[k];
            uint8 st = tokenStatus(id);
            if (st == 0 || st == 4) continue;
            uint32 eos = tokenHarvestTs(id);
            uint32 sos = uint32(id >> 172);
            if (eos <= sos) eos = HELD_UNTIL_REPORTED; // no usable harvest date: until reported
            _claimFields(uint32(id >> 224), uint128((id >> 20) & ((uint256(1) << 128) - 1)), eos);
        }
    }

    // ================================================================
    //  SALES FROM AN OPEN BATCH (P1)
    // ================================================================

    function _setBatch(uint256 tokenId, uint256 batchId) internal {
        uint256 m = _tokenMeta[tokenId];
        m &= ~(uint256(type(uint64).max) << 40);
        _tokenMeta[tokenId] = m | (uint256(uint64(batchId)) << 40);
    }

    /// @notice The union sells part of its standing (open) batch: the chosen tokens —
    ///         each one field's harvest in one season, never split — move into a new
    ///         sold batch for `buyer`. The rest stays open. Token ids do not change, so
    ///         anything that refers to a token (the Stellar attestation, her loan) holds.
    function sellFromBatch(
        uint256 openBatchId,
        address buyer,
        uint32  deliveryDate,
        uint256 pricePerKgUsdt,
        uint256[] calldata tokenIds
    ) external whenNotPaused returns (uint256 soldBatchId) {
        if (buyer == address(0)) revert ZeroAddress();
        Batch storage o = batches[openBatchId];
        if (!_isUnionAuth(o.union_)) revert NotAuthorized();
        if (!o.active) revert BatchNotActive();
        if (o.buyer != address(0)) revert NotStanding();
        if (tokenIds.length == 0) revert TokenNotFound();

        soldBatchId = ++nextBatchId;
        uint256 qty;
        for (uint256 k = 0; k < tokenIds.length; k++) {
            uint256 id = tokenIds[k];
            uint8 st = tokenStatus(id);
            if (st == 0 || st == 4) revert TokenNotFound();
            if (tokenBatch(id) != openBatchId) revert TokenNotInBatch();
            qty += balanceOf(_holderOf(id), id);
            _setBatch(id, soldBatchId);
        }
        o.claimedQtyKg = o.claimedQtyKg > qty ? o.claimedQtyKg - qty : 0;
        batches[soldBatchId] = Batch({
            union_:         o.union_,
            cropCode:       o.cropCode,
            varietyCode:    o.varietyCode,
            active:         true,
            conditions:     o.conditions,
            buyer:          buyer,
            targetQtyKg:    qty,
            claimedQtyKg:   qty,
            deliveryDate:   deliveryDate,
            pricePerKgUsdt: pricePerKgUsdt,
            status:         1, // filled: every kg is already in it
            requiredCerts:  o.requiredCerts
        });
        emit BatchCreated(soldBatchId, o.union_, o.cropCode, o.varietyCode, buyer);
        emit BatchStatusUpdated(soldBatchId, 1);
        emit TokensSold(openBatchId, soldBatchId, tokenIds, qty);
    }

    // ================================================================
    //  VIEW FUNCTIONS
    // ================================================================

    function getBatch(uint256 batchId) external view returns (Batch memory) {
        return batches[batchId];
    }

    function getLandTitleTokens(uint32 landTitleId) external view returns (uint256[] memory) {
        return landTitleTokens[landTitleId];
    }

    function isStanding(uint256 batchId) external view returns (bool) {
        return batches[batchId].buyer == address(0);
    }

    // ================================================================
    //  UUPS + ADMIN
    // ================================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
