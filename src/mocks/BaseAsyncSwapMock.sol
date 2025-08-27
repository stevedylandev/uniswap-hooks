// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseAsyncSwap} from "src/base/BaseAsyncSwap.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract BaseAsyncSwapMock is BaseAsyncSwap {
    constructor(IPoolManager _poolManager) BaseAsyncSwap(_poolManager) {}

    // Exclude from coverage report
    function test() public {}
}
