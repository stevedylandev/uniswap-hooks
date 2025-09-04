// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseOverrideFee} from "../fee/BaseOverrideFee.sol";

contract BaseOverrideFeeMock is BaseOverrideFee {
    uint24 private _fee;

    constructor(IPoolManager _poolManager) BaseOverrideFee(_poolManager) {}

    function _getFee(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _fee;
    }

    function setFee(uint24 fee_) public {
        _fee = fee_;
    }

    // Exclude from coverage report
    function test() public {}
}
