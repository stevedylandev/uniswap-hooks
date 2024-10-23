// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/AntiSandwichHook.sol)

pragma solidity ^0.8.20;

import {DynamicAfterFee} from "src/fee/DynamicAfterFee.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev Implementation of an anti-sandwich hook.
 *
 * Based on the https://github.com/cairoeth/sandwich-resistant-hook/blob/master/src/srHook.sol[implementation by cairoeth].
 *
 * _Available since v0.1.0_
 */
contract AntiSandwichHook is DynamicAfterFee {
    using PoolIdLibrary for PoolKey;
    using Pool for *;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
        Pool.State state;
    }

    mapping(PoolId => Checkpoint) private _lastCheckpoints;

    constructor(IPoolManager _poolManager) DynamicAfterFee(_poolManager) {}

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // update the top-of-block `slot0` if new block
        if (_lastCheckpoint.blockNumber != uint32(block.number)) {
            _lastCheckpoint.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
        } else {
            // constant bid price
            if (!params.zeroForOne) {
                _lastCheckpoint.state.slot0 = _lastCheckpoint.slot0;
            }

            (_targetDeltas[poolId],,,) = Pool.swap(
                _lastCheckpoint.state,
                Pool.SwapParams({
                    tickSpacing: key.tickSpacing,
                    zeroForOne: params.zeroForOne,
                    amountSpecified: params.amountSpecified,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    lpFeeOverride: 0
                })
            );
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        uint32 blockNumber = uint32(block.number);
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // after the first swap in block, initialize the temporary pool state
        if (_lastCheckpoint.blockNumber != blockNumber) {
            _lastCheckpoint.blockNumber = blockNumber;

            // iterate over ticks
            (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
            for (int24 tick = _lastCheckpoint.slot0.tick(); tick < tickAfter; tick += key.tickSpacing) {
                (
                    uint128 liquidityGross,
                    int128 liquidityNet,
                    uint256 feeGrowthOutside0X128,
                    uint256 feeGrowthOutside1X128
                ) = poolManager.getTickInfo(poolId, tick);
                _lastCheckpoint.state.ticks[tick] =
                    Pool.TickInfo(liquidityGross, liquidityNet, feeGrowthOutside0X128, feeGrowthOutside1X128);
            }

            // deep copy only values that are used and change in fair delta calculation
            _lastCheckpoint.state.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
            (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) = poolManager.getFeeGrowthGlobals(poolId);
            _lastCheckpoint.state.feeGrowthGlobal0X128 = feeGrowthGlobal0;
            _lastCheckpoint.state.feeGrowthGlobal1X128 = feeGrowthGlobal1;
            _lastCheckpoint.state.liquidity = poolManager.getLiquidity(poolId);
        }

        return super._afterSwap(sender, key, params, delta, hookData);
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
