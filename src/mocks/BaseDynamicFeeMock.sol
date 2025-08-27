// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseDynamicFee} from "src/fee/BaseDynamicFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract BaseDynamicFeeMock is BaseDynamicFee {
    uint24 private _fee;

    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    function _getFee(PoolKey calldata) internal view override returns (uint24) {
        return _fee;
    }

    function setFee(uint24 fee_) public {
        _fee = fee_;
    }

    // Exclude from coverage report
    function test() public {}
}
