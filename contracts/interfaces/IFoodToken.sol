// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title IFoodToken
/// @notice Interface consumed by GenericFundCore (drawLoan / Track C).
///
/// TokenId encodes the full crop codex (see FoodTokenUpgradeable):
///   [255:224] landTitleId · [223:204] cropCode (6-digit: cropFamily*1000 + variety)
///   [203:172] sosTs (full unix ts) · [171:148] areaM2 · [147:20] fieldsBitmask
///
interface IFoodToken {

    // ----------------------------------------------------------------
    // Token identity — decoded from tokenId directly (SOS included)
    // ----------------------------------------------------------------

    function unpackTokenId(uint256 tokenId) external pure returns (
        uint32  landTitleId,
        uint32  cropCode,
        uint32  sosTs,
        uint32  areaM2,
        uint128 fieldsBitmask
    );

    // ----------------------------------------------------------------
    // Mutable per-token state (SOS is in the tokenId, not here)
    // ----------------------------------------------------------------

    function tokenHarvestTs(uint256 tokenId) external view returns (uint32);

    /// @notice 0=unminted 1=active 2=verified 3=harvested 4=cancelled
    function tokenStatus(uint256 tokenId)    external view returns (uint8);

    // ----------------------------------------------------------------
    // ERC1155 standard — balance IS the committed qty in kg
    // ----------------------------------------------------------------

    function balanceOf(address account, uint256 id) external view returns (uint256);

    // ----------------------------------------------------------------
    // Oracle write — called by GenericFundCore on default
    // ----------------------------------------------------------------

    function updateTokenStatus(uint256 tokenId, uint8 status) external;

    // ----------------------------------------------------------------
    // ERC1155 transfer — lock / release collateral
    // ----------------------------------------------------------------

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external;
}
