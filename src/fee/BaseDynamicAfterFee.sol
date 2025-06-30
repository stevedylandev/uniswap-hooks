// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseDynamicAfterFee.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHookEvents} from "src/interfaces/IHookEvents.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
/**
 * @dev Base implementation for dynamic fees applied after swaps.
 *
 * Enables to enforce a dynamic target determined by {_getTargetUnspecifiedAmount} for the unspecified currency
 * of the swap, taking any positive difference as fee, handling or distributing the fees via {_afterSwapHandler}.
 *
 * NOTE: In order to use this hook, the inheriting contract must implement {_getTargetUnspecifiedAmount} and
 * {_afterSwapHandler}.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */

abstract contract BaseDynamicAfterFee is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    /**
     * @dev Target unspecified amount to be enforced by the `afterSwap`, taking any surplus as fees.
     */
    uint256 internal _targetUnspecifiedAmount;

    /**
     * @dev Determines if the target unspecified amount should be applied to the swap.
     */
    bool internal _applyTargetUnspecifiedAmount;

    /**
     * @dev Set the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Sets the target unspecified amount and apply flag to be used in the `afterSwap` hook.
     *
     * NOTE: The target unspecified amount and the apply flag are reset in the `afterSwap`.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get and store the target unspecified amount and the apply flag, overriding any previous values.
        (_targetUnspecifiedAmount, _applyTargetUnspecifiedAmount) =
            _getTargetUnspecifiedAmount(sender, key, params, hookData);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Enforce the target unspecified amount to the unspecified currency of the swap.
     *
     * When the swap is exactInput and the output target is surpassed, the difference is decreased from the output as a fee.
     * Accordingly, when the swap is exactOutput and the input target is not reached, the difference is increased to the
     * input as a fee. Note that the fee is always applied to the unspecified currency of the swap, regardless of the swap
     * direction.
     *
     * The fees are minted to this hook as ERC-6909 tokens, which can then be distribuited in {_afterSwapHandler}
     *
     * NOTE: The target unspecified amount and the apply flag are reset on purpose to avoid state overlapping across swaps.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        // Cache the target unspecified amount in memory
        uint256 targetUnspecifiedAmount = _targetUnspecifiedAmount;

        // Reset stored target unspecified amount to 0, use the cached value in memory.
        _targetUnspecifiedAmount = 0;

        // Skip if the target unspecified amount should not be applied
        if (!_applyTargetUnspecifiedAmount) {
            return (this.afterSwap.selector, 0);
        }

        // Reset the stored apply flag
        _applyTargetUnspecifiedAmount = false;

        // Fee defined in the unspecified currency of the swap
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // Get the absolute unspecified amount
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        bool exactInput = params.amountSpecified < 0;

        uint256 feeAmount;

        // If the swap is exact input => any fee should be decreased from the output
        if (exactInput) {
            // If the user is getting more than the target
            if (unspecifiedAmount.toUint256() > targetUnspecifiedAmount) {
                // decrease what he will receive (outputAmount)
                feeAmount = unspecifiedAmount.toUint256() - targetUnspecifiedAmount;
            }
            // If the user is getting less or equal than the target.. do nothing @tbd 
        }

        // If the swap is exact output => any fee should be increased to the input
        if (!exactInput) {
            // If the user is paying less than the target
            if (unspecifiedAmount.toUint256() < targetUnspecifiedAmount) {
                // Increase what he will pay (inputAmount)
                feeAmount = targetUnspecifiedAmount - unspecifiedAmount.toUint256();
            }
            // If the user is paying more or equal than the target.. do nothing @tbd
        }

        // Mint ERC-6909 tokens for unspecified currency fee and call handler
        if (feeAmount > 0) {
            unspecified.take(poolManager, address(this), feeAmount, true);
            _afterSwapHandler(key, params, delta, targetUnspecifiedAmount, feeAmount);
        }

        // Emit the swap event with the amounts ordered correctly
        if (unspecified == key.currency0) {
            emit HookFee(PoolId.unwrap(key.toId()), sender, feeAmount.toUint128(), 0);
        } else {
            emit HookFee(PoolId.unwrap(key.toId()), sender, 0, feeAmount.toUint128());
        }

        return (this.afterSwap.selector, feeAmount.toInt256().toInt128());
    }

    /**
     * @dev Return the target unspecified amount to be enforced by the `afterSwap` hook using fees.
     *
     * TIP: In order to consume all of the swap unspecified amount, set the target equal to zero and set the apply
     * flag to `true`.
     *
     * @return targetUnspecifiedAmount The target unspecified amount, defined in the unspecified currency of the swap.
     * @return applyTargetUnspecifiedAmount The apply flag, which can be set to `false` to skip applying the target output.
     */
    function _getTargetUnspecifiedAmount(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual returns (uint256 targetUnspecifiedAmount, bool applyTargetUnspecifiedAmount);

    /**
     * @dev Customizable handler called after `_afterSwap` to handle or distribuite the fees.
     *
     * WARNING: If the underlying unspecified currency is native, the implementing contract must ensure that it can
     * receive and handle it when redeeming.
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint256 targetOutput,
        uint256 feeAmount
    ) internal virtual;

    /**
     * @dev Set the hook permissions, specifically {beforeSwap}, {afterSwap} and {afterSwapReturnDelta}.
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
