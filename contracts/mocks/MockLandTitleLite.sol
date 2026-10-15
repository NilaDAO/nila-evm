// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// Minimal land title for FoodToken tests: owner and oracle commitment per title.
contract MockLandTitleLite {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bytes32) public getCommitment;

    function set(uint256 id, address owner, bytes32 commitment) external {
        ownerOf[id] = owner;
        getCommitment[id] = commitment;
    }
}
