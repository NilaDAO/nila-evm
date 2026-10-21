// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface ILandTitleRead {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getCommitment(uint256 tokenId) external view returns (bytes32);
}

/// DEMO FORK ONLY — never deployed on a live chain. The demo's land titles live on Stellar testnet only (ids 900043+),
/// so on the local Polygon fork FoodToken reads its land titles through this view: a demo id answers from the table
/// the demo sets (her Polygon wallet and her record hash), every other id from the real NilaLandTitle.
contract DemoLandTitleView is ILandTitleRead {
    ILandTitleRead public immutable real;
    address public immutable admin;
    mapping(uint256 => address) public demoOwner;
    mapping(uint256 => bytes32) public demoCommitment;

    constructor(address real_) { real = ILandTitleRead(real_); admin = msg.sender; }

    function set(uint256 id, address owner, bytes32 commitment) external {
        require(msg.sender == admin, "admin only");
        demoOwner[id] = owner;
        demoCommitment[id] = commitment;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = demoOwner[id];
        return o != address(0) ? o : real.ownerOf(id);
    }

    function getCommitment(uint256 id) external view returns (bytes32) {
        return demoOwner[id] != address(0) ? demoCommitment[id] : real.getCommitment(id);
    }
}
