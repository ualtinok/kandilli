// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

import "../../interfaces/IAuctionable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockAuctionableToken is IAuctionable, ERC721, Ownable {
    uint256 private counter = 0;

    constructor() ERC721("MockToken", "Mock") {
        _transferOwnership(msg.sender);
    }

    function settle(address to, uint256 entropy) external {
        _safeMint(to, counter++);
    }

    function getGasCost() external view returns (uint256) {
        return 200000;
    }
}
