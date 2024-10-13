// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "src/base/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

abstract contract DynamicAfterFee is BaseHook {
    mapping(PoolId => BalanceDelta) internal _targetDeltas;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        BalanceDelta targetDelta = _targetDeltas[poolId];
        int128 feeAmount = 0;
        if (BalanceDelta.unwrap(targetDelta) != 0) {
            if (delta.amount0() == targetDelta.amount0() && delta.amount1() > targetDelta.amount1()) {
                feeAmount = delta.amount1() - targetDelta.amount1();
                poolManager.donate(key, 0, uint256(uint128(feeAmount)), "");
            }

            if (delta.amount1() == targetDelta.amount1() && delta.amount0() > targetDelta.amount0()) {
                feeAmount = delta.amount0() - targetDelta.amount0();
                poolManager.donate(key, uint256(uint128(feeAmount)), 0, "");
            }

            _targetDeltas[poolId] = BalanceDelta.wrap(0);
        }

        return (this.afterSwap.selector, feeAmount);
    }

    /// @notice Set the permissions for the hook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
