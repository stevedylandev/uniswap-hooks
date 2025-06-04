// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/general/AntiSandwichHook.sol";

interface IMsgSender {
    function msgSender() external view returns (address);
}

contract AntiSandwichHookMsgSenderMock is AntiSandwichHook {

    mapping(address swapRouter => bool approved) public verifiedRouters;

    error UnauthorizedRouter(address router);

    constructor(IPoolManager _poolManager) AntiSandwichHook(_poolManager) {}

    function addRouter(address _router) external {
        verifiedRouters[_router] = true;
    }

    function _getUserAddress(address router) internal override returns (address) {
        if (!verifiedRouters[router]) {
            revert UnauthorizedRouter(router);
        }
        address msgSender = IMsgSender(router).msgSender();
        return msgSender;
    }
}