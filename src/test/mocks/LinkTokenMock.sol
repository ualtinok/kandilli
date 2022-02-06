// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract LinkTokenMock is ERC20Mock {
    bytes32 internal keyHash;
    uint256 internal seed;
    address internal requester;
    mapping(bytes32 => uint256) internal nonces;

    constructor(
        string memory name,
        string memory symbol,
        address initialAccount,
        uint256 initialBalance
    ) payable ERC20Mock(name, symbol, initialAccount, initialBalance) {}

    function transferAndCall(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external returns (bool) {
        _to;
        _value;
        (keyHash, seed) = abi.decode(_data, (bytes32, uint256));
        requester = msg.sender;
        nonces[keyHash]++;
        return true;
    }

    /*    function balanceOf(address _account)
        external
        pure
        returns (uint256 balanceOf_)
    {
        _account;
        balanceOf_ = 5e18;
    }*/

    function getRequestId() external view returns (bytes32 requestId_) {
        bytes32 input = keccak256(abi.encode(keyHash, seed, requester, nonces[keyHash] - 1));
        requestId_ = keccak256(abi.encodePacked(keyHash, input));
    }
}
