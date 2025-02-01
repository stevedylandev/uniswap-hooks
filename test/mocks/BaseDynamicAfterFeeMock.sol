// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseDynamicAfterFee.sol";

contract BaseDynamicAfterFeeMock is BaseDynamicAfterFee {
    mapping(PoolId => uint256) public targetOutput;
    bool public applyTargetOutput;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function getTargetOutput(PoolId poolId) public view returns (uint256) {
        return _getTargetOutput(poolId);
    }

    function setTargetOutput(PoolId poolId, uint256 output, bool active) public {
        targetOutput[poolId] = output;
        applyTargetOutput = active;
    }

    function _afterSwapHandler(PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, uint256, uint256)
        internal
        override
    {}

    function _getTargetOutput(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint256, bool)
    {
        return (targetOutput[key.toId()], applyTargetOutput);
    }

    // Exclude from coverage report
    function test() public {}
}
