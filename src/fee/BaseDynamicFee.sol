// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseDynamicFee.sol)

pragma solidity ^0.8.20;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @dev Base implementation for dynamic fees applied before swaps.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseDynamicFee is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = _beforeSwap(sender, key, params, hookData);
        return (selector, delta, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = _beforeSwap(sender, key, params, hookData);
        return (selector, delta, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
