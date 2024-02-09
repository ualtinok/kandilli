// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../../interfaces/IAuctionable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockAuctionableToken is IAuctionable, ERC721, Ownable {
    uint256 private counter = 0;

    mapping(uint256 => uint256) public uniq;

    constructor() ERC721("MockToken", "Mock") {
        _transferOwnership(msg.sender);
    }

    function settle(address to, uint256 entropy) external returns (uint256 tokenId) {
        uniq[counter] = entropy;
        tokenId = counter;
        _safeMint(to, counter++);
    }

    function getGasCost() external view returns (uint32) {
        return 80000;
    }
}
