// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "hardhat/console.sol";

interface IFundCore {
    function viewer() external view returns (address);
    function isOracleSigner(address) external view returns (bool);
    function roles() external view returns (address); // <- auto-getter on core
    
    function mintJuniorSharesFromFoodTokenValuation(
        address unionAddr, bytes32 loanType, address investor, uint256 quoteAmount
    ) external returns (uint256);
}

interface IRolesLike {
    function isOracle(address account) external view returns (bool);
}

interface IViewer {
    function recoverQuote1155Signer(
        address coreAddr,
        address unionAddr,
        bytes32 loanType,
        address investor,
        address collection,
        uint256 id,
        uint256 amount1155,
        uint256 quoteAmount,
        uint40  expiry,
        bytes calldata sig
    ) external view returns (address);
}

contract GenericFund1155Module is Ownable, ReentrancyGuard, ERC1155Holder {
    // ---- storage ----
    IFundCore public immutable core;

    // allowlist: union => loanType => collection => id => allowed
    mapping(address => mapping(bytes32 => mapping(address => mapping(uint256 => bool)))) public is1155Allowed;

    struct Lot {
        address owner;
        address unionAddr;
        bytes32 loanType;
        address collection;
        uint256 id;
        uint256 amount1155;
        uint256 sharesMinted;  // shares created from quote
        bool    active;
    }
    uint256 public nextLotId;
    mapping(uint256 => Lot) public lots;

    // events
    event depositedFoodTokens( address indexed unionAddr,address indexed investor, bytes32 indexed loanType,address collection,uint256 id,uint256 amount1155,uint256 quoteAmount,uint256 shares,uint256 lotId );
    event ERC1155AllowedSet(address indexed unionAddr, bytes32 indexed loanType, address indexed collection, uint256 id, bool allowed);


    // errors
    error ZeroAmount();
    error QuoteExpired();
    error NotAllowed();
    error NotCore();
    error LotInvalid();
    error LotMismatch();
    error ModuleNotAuth();

    modifier onlyCore() {
        if (msg.sender != address(core)) revert NotCore();
        _;
    }

    constructor(address core_, address initialOwner) Ownable(initialOwner) {
        require(core_ != address(0), "core=0");
        core = IFundCore(core_);
    }

    // ---- admin ----
    function set1155Allowed(
        address unionAddr,
        bytes32 loanType,
        address collection,
        uint256 id,
        bool allowed
        ) external onlyOwner {
        is1155Allowed[unionAddr][loanType][collection][id] = allowed;
        emit ERC1155AllowedSet(unionAddr, loanType, collection, id, allowed);
    }

    // ---------- Module hooks (1155) ----------
    /*
        How does it work: 
        * We are using erc1155 tokens as collateral only
        * It isnt used as reserve, so onFoodTokenDelta and onReservedPrincipalDelta are not yet needed
        * In case we would count them as virtual liquidity (and earn interest on them, monitor pricing), we need to manage pricing fluctuations and reserve changes. 
    */
    /*
    function onFoodTokenDelta(address unionAddr, int256 delta) external {
        if (!(roles.isOracle(msg.sender) || msg.sender == owner())) revert ModuleNotAuth();
        if (delta > 0) foodTokenLiquidity[unionAddr] += uint256(delta);
        else if (delta < 0) foodTokenLiquidity[unionAddr] -= uint256(-delta);
    }

    function onReservedPrincipalDelta(address unionAddr, int256 delta) external {
        if (!(roles.isOracle(msg.sender) || msg.sender == owner())) revert ModuleNotAuth();
        _bumpUnionClaimable(unionAddr, delta);
    }
    // allow your 1155 module to be an oracle caller or keep a dedicated setter for module address
    function mintJuniorSharesFromFoodTokenValuation(
        address unionAddr,
        bytes32 loanType,
        address investor,
        uint256 quoteAmount
        ) external nonReentrant returns (uint256 _shares) {
        // Auth: only oracle or owner (module should be registered as oracle)
        if (!(roles.isOracle(msg.sender) || msg.sender == owner())) revert ModuleNotAuth();
        if (quoteAmount == 0) revert AmountZero();

        // Junior gating enforced in Core
        _requireHoldsNFT(investor);

        _ensureJuniorMarket(unionAddr, loanType);

        // Settle investor yield before changing share balance
        _settleYield(juniorInv[unionAddr][loanType][investor], junior[unionAddr][loanType].index);

        JuniorMarket storage m = junior[unionAddr][loanType];
        uint256 pps = m.index == 0 ? GenericFundMathLib.RAY : m.index;
        uint256 shares = (quoteAmount * GenericFundMathLib.RAY) / pps;

        m.totalShares += shares;

        Investor storage inv = juniorInv[unionAddr][loanType][investor];
        inv.shares += shares;
        if (inv.entryIndex == 0) inv.entryIndex = pps;

        emit Deposit(investor, ICore.Tranche.JUNIOR, unionAddr, loanType, quoteAmount, shares);
        return shares;
    }
    */

    // ---- user flow: invest ERC1155 into a junior bucket via oracle quote ----
    function depositFoodTokens(
        address unionAddr,
        bytes32 loanType,
        address collection,
        uint256 id,
        uint256 amount1155,
        uint256 quoteAmount,
        uint40  expiry,
        bytes calldata oracleSig
    ) external nonReentrant {
        if (amount1155 == 0 || quoteAmount == 0) revert ZeroAmount();
        if (!is1155Allowed[unionAddr][loanType][collection][id]) revert NotAllowed();
        if (block.timestamp > expiry) revert QuoteExpired();

        // ✅ verify oracle quote using the Viewer (OZ v4 domain shape),
        //    but with Core address as the verifyingContract
        address viewerAddr = core.viewer();
        address signer = IViewer(viewerAddr).recoverQuote1155Signer(
            address(core),            // verifyingContract in the domain
            unionAddr,
            loanType,
            msg.sender,               // investor
            collection,
            id,
            amount1155,
            quoteAmount,
            expiry,
            oracleSig
        );

        address rolesAddr = IFundCore(address(core)).roles();
        if (!IRolesLike(rolesAddr).isOracle(signer)) revert NotAllowed();

        // escrow 1155
        IERC1155(collection).safeTransferFrom(msg.sender, address(this), id, amount1155, "");

        // mint junior shares in core based on quote
        uint256 shares = core.mintJuniorSharesFromFoodTokenValuation(unionAddr, loanType, msg.sender, quoteAmount);

        // record lot for in-kind redemption
        uint256 lotId = ++nextLotId;
        lots[lotId] = Lot({
            owner: msg.sender,
            unionAddr: unionAddr,
            loanType: loanType,
            collection: collection,
            id: id,
            amount1155: amount1155,
            sharesMinted: shares,
            active: true
        });

        emit depositedFoodTokens(unionAddr, msg.sender, loanType, collection, id, amount1155, quoteAmount, shares, lotId);
    }

    // ---- called by Core on request-withdraw validation ----
    function validateLot(
        address owner,
        address unionAddr,
        bytes32 loanType,
        uint256 shares,
        uint256 lotId
    ) external view returns (bool) {
        Lot storage L = lots[lotId];
        if (!L.active) return false;
        if (L.owner != owner) return false;
        if (L.unionAddr != unionAddr || L.loanType != loanType) return false;
        if (L.sharesMinted != shares) return false;
        return true;
    }

    // ---- called by Core during claimWithdraw for in-kind path ----
    function redeemLot(
        address to,
        uint256 lotId,
        address unionAddr,
        bytes32 loanType,
        uint256 shares
    ) external onlyCore {
        Lot storage L = lots[lotId];
        if (!(L.active && L.owner == to)) revert LotInvalid();
        if (L.unionAddr != unionAddr || L.loanType != loanType) revert LotMismatch();
        if (L.sharesMinted != shares) revert LotMismatch();

        IERC1155(L.collection).safeTransferFrom(address(this), to, L.id, L.amount1155, "");
        L.active = false;
    }
}
