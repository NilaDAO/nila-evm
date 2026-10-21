// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// Test roles registry: leaders per union.
contract MockRoles {
    mapping(address => mapping(address => bool)) public leader;
    function setLeader(address union_, address acct, bool on) external { leader[union_][acct] = on; }
    function isLeader(address union_, address acct) external view returns (bool) { return leader[union_][acct]; }
    function isOracle(address) external pure returns (bool) { return false; }
}
