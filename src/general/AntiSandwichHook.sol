// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/general/AntiSandwichHook.sol)

pragma solidity ^0.8.24;

import {BaseDynamicAfterFee} from "src/fee/BaseDynamicAfterFee.sol";
import {BaseHook} from "src/base/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {console} from "forge-std/console.sol";

/**
 * @dev Sandwich-resistant hook, based on
 * https://github.com/cairoeth/sandwich-resistant-hook/blob/master/src/srHook.sol[this]
 * implementation.
 *
 * This hook implements the sandwich-resistant AMM design introduced
 * https://www.umbraresearch.xyz/writings/sandwich-resistant-amm[here]. Specifically,
 * this hook guarantees that no swaps get filled at a price better than the price at
 * the beginning of the slot window (i.e. one block).
 *
 * Within a slot window, swaps impact the pool asymmetrically for buys and sells.
 * When a buy order is executed, the offer on the pool increases in accordance with
 * the xy=k curve. However, the bid price remains constant, instead increasing the
 * amount of liquidity on the bid. Subsequent sells eat into this liquidity, while
 * decreasing the offer price according to xy=k.
 *
 * NOTE: Swaps in the other direction do not get the positive price difference
 * compared to the initial price before the first block swap.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
contract AntiSandwichHook is BaseDynamicAfterFee {
    using Pool for *;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
        Pool.State state;
    }

    mapping(PoolId id => Checkpoint) private _lastCheckpoints;
    mapping(PoolId => BalanceDelta) private _fairDeltas;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // update the top-of-block `slot0` if new block
        if (_lastCheckpoint.blockNumber != uint32(block.number)) {
            _lastCheckpoint.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
        } else {
            // constant bid price
            // if (!params.zeroForOne) {
            //     _lastCheckpoint.state.slot0 = _lastCheckpoint.slot0;
            // }

            //(uint256 targetOutput, bool applyTargetOutput) = _getTargetOutput(sender, key, params, hookData);

            // (_fairDeltas[poolId],,,) = Pool.swap(
            //     _lastCheckpoint.state,
            //     Pool.SwapParams({
            //         tickSpacing: key.tickSpacing,
            //         zeroForOne: params.zeroForOne,
            //         amountSpecified: params.amountSpecified,
            //         sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            //         lpFeeOverride: 0
            //     })
            // );

            (uint256 targetOutput, bool applyTargetOutput) = _getTargetOutput(sender, key, params, hookData);

            _targetOutput = targetOutput;
            _applyTargetOutput = applyTargetOutput;
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
            (_lastCheckpoint.state.feeGrowthGlobal0X128, _lastCheckpoint.state.feeGrowthGlobal1X128) =
                poolManager.getFeeGrowthGlobals(poolId);
            _lastCheckpoint.state.liquidity = poolManager.getLiquidity(poolId);
        }

        BalanceDelta _fairDelta = _fairDeltas[poolId];
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if(unspecifiedAmount < 0) {
            unspecifiedAmount = -unspecifiedAmount;
        }

        if(_targetOutput > uint256(uint128(unspecifiedAmount))) {
            _targetOutput = uint256(uint128(unspecifiedAmount));
        }

        //return (this.afterSwap.selector, feeAmount);

        return super._afterSwap(sender, key, params, delta, hookData);
    }

    function _getTargetOutput(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (uint256 targetOutput, bool applyTargetOutput) {
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        if (!params.zeroForOne) {
            _lastCheckpoint.state.slot0 = _lastCheckpoint.slot0;
        }


        (BalanceDelta targetDelta,,,) = Pool.swap(
            _lastCheckpoint.state,
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );

        console.log("targetDelta.amount0()", targetDelta.amount0());
        console.log("targetDelta.amount1()", targetDelta.amount1());

        int128 target = (params.amountSpecified < 0 == params.zeroForOne) ? targetDelta.amount1() : targetDelta.amount0();

        if (target < 0) {
            target = -target;
        }

        targetOutput = uint256(uint128(target));
        applyTargetOutput = true;
    }

    // function _getTargetOutput(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     bytes calldata hookData
    // ) internal override returns (uint256 targetOutput, bool applyTargetOutput) {

    //     Checkpoint storage _lastCheckpoint = _lastCheckpoints[key.toId()];

    //     if (!params.zeroForOne) {
    //         _lastCheckpoint.state.slot0 = _lastCheckpoint.slot0;
    //     }

    //     (BalanceDelta outputDelta,,,) = Pool.swap(
    //         _lastCheckpoint.state,
    //         Pool.SwapParams({
    //             tickSpacing: key.tickSpacing,
    //             zeroForOne: params.zeroForOne,
    //             amountSpecified: params.amountSpecified,
    //             sqrtPriceLimitX96: params.sqrtPriceLimitX96,
    //             lpFeeOverride: 0
    //         })
    //     );
    //     console.log("zeroForOne", params.zeroForOne);
    //     console.log("amountSpecified", params.amountSpecified);
    //     console.log("outputDelta.amount1()", outputDelta.amount1());
    //     console.log("outputDelta.amount0()", outputDelta.amount0());

    //     if(params.zeroForOne) {
    //         int128 outputAmount = outputDelta.amount1() >= 0 ? outputDelta.amount1() : -outputDelta.amount1();
    //         targetOutput = uint256(uint128(outputAmount));
    //     }

    //     console.log("targetOutput", targetOutput);

    //     applyTargetOutput = true;
    // }

    function _afterSwapHandler(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        uint256 targetOutput,
        uint256 feeAmount
    ) internal override {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);

        // (uint256 amount0, uint256 amount1) = unspecified == key.currency0 ? (uint256(uint128(feeAmount)), 0) : (0, uint256(uint128(feeAmount)));

        uint256 amount0 = unspecified == key.currency0 ? uint256(uint128(feeAmount)) : 0;
        uint256 amount1 = unspecified == key.currency1 ? uint256(uint128(feeAmount)) : 0;

        //unspecified.settle(poolManager, address(this), feeAmount, true);
        poolManager.donate(key, amount0, amount1, "");

        _targetOutput = 0;
        _applyTargetOutput = false;

        unspecified.settle(poolManager, address(this), feeAmount, true);

        // // Burn ERC-6909 and take underlying tokens
        // unspecified.settle(poolManager, address(this), feeAmount, true);
        // unspecified.take(poolManager, address(this), feeAmount, false);
    }

    /**
     * @dev Set the hook permissions, specifically `beforeSwap`, `afterSwap`, and `afterSwapReturnDelta`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
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
