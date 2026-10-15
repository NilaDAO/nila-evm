// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRolesRegistry {
    function isLeader(address unionAddr, address acct) external view returns (bool);
    function isOracle(address acct) external view returns (bool);
}
