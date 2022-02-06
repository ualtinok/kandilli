// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

interface IAuctionable {
    function settle(address to, uint256 entropy) external;
    function getGasCost() external view returns (uint256);
}