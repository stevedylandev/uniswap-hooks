// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/fee/BaseDynamicFee.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract BaseDynamicFeeMock is BaseDynamicFee {
    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    function _getFee(PoolKey calldata) internal pure override returns (uint24) {
        return 50000;
    }
}
