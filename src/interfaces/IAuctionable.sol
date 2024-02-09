// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

interface IAuctionable {
    function settle(address to, uint256 entropy) external returns (uint256);

    function getGasCost() external view returns (uint32);
}
