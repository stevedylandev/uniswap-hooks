// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseDynamicAfterFee.sol";

contract BaseDynamicAfterFeeMock is BaseDynamicAfterFee {
    uint256 public targetOutput;
    bool public applyTargetOutput;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function getTargetOutput() public view returns (uint256) {
        return _getTargetOutput();
    }

    function setTargetOutput(uint256 output, bool active) public {
        targetOutput = output;
        applyTargetOutput = active;
    }

    function _afterSwapHandler(PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, uint256, uint256)
        internal
        override
    {}

    function _getTargetOutput(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint256, bool)
    {
        return (targetOutput, applyTargetOutput);
    }

    // Exclude from coverage report
    function test() public {}
}
