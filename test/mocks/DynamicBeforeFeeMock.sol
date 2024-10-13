// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/base/DynamicBeforeFee.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract DynamicBeforeFeeMock is DynamicBeforeFee {
    constructor(IPoolManager _poolManager) DynamicBeforeFee(_poolManager) {}

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 50000);
    }
}
