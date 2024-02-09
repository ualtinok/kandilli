// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import { PRBTest } from "@prb/test/src/PRBTest.sol";
import {Vm} from "forge-std/src/Vm.sol";

struct Data {
    string name;
}

//common utilities for forge tests
contract Utilities is PRBTest {
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));

    function getRandomNumber() external returns (uint256) {
        // This is to get a random number via FFI. Can comment out and enable ffi via (test --ffi or via toml)
        // Requires nodejs installed
        string[] memory inputs = new string[](2);
        inputs[0] = "node";
        inputs[1] = "scripts/rand.js";
        bytes memory res = vm.ffi(inputs);
        Data memory data = abi.decode(res, (Data));
        return uint256(keccak256(abi.encode(data.name)));
    }

    function getNextUserAddress() external returns (address payable) {
        //bytes32 to address conversion
        address payable user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    //create users with 100 ether balance
    function createUsers(uint256 userNum) external returns (address payable[] memory) {
        address payable[] memory users = new address payable[](userNum);
        for (uint256 i = 0; i < userNum; i++) {
            address payable user = this.getNextUserAddress();
            vm.deal(user, 100 ether);
            users[i] = user;
        }
        return users;
    }

    //move block.number forward by a given number of blocks
    function mineBlocks(uint256 numBlocks) external {
        uint256 targetBlock = block.number + numBlocks;
        vm.roll(targetBlock);
    }

    function getNamedUser(string memory name) external returns (address payable) {
        return payable(address(uint160(uint256(keccak256(abi.encodePacked(name))))));
    }
}
