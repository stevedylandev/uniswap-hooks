// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/general/AntiSandwichHook.sol";

contract AntiSandwichHookNoMsgSenderMock is AntiSandwichHook {

    error NoAccessToMsgSender();

    constructor(IPoolManager _poolManager) AntiSandwichHook(_poolManager) {}

    function _getUserAddress(address router) internal view override returns (address) {
        revert NoAccessToMsgSender();
    }
}