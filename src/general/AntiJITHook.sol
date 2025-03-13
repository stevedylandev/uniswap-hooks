// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.1) (src/general/AntiJITHook.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/**
 * @dev This hook implements a mechanism to prevent JIT (Just in Time) attacks on liquidity pools. Specifically,
 * it checks if a liquidity position was added to the pool within a certain block number range (at least 1 block)
 * and if so, it donates the fees to the pool. This way, the hook effectively taxes JIT attackers by donating their
 * expected profits back to the pool.
 *
 * At constructor, the hook requires a block number offset. This offset is the number of blocks at which the hook
 * will donate the fees to the pool. The minimum value is 1.
 *
 * NOTE: The hook donates the fees to the current in range liquidity providers (at the time of liquidity removal).
 * If the block number offset is much later than the actual block number when the liquidity was added, the
 * liquidity providers who benefited from the fees will be the ones in range at the time of liquidity removal, not
 * the ones in range at the time of liquidity addition.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.1_
 */
contract AntiJITHook is BaseHook {
    using CurrencySettler for Currency;

    /**
     * @notice The minimum block number amount for the offset.
     */
    uint256 public constant MIN_BLOCK_NUMBER_OFFSET = 1;

    /**
     * @notice Tracks the last block number when a liquidity position was added to the pool.
     */
    mapping(PoolId id => mapping(bytes32 positionKey => uint256 blockNumber)) public _lastAddedLiquidity;

    /**
     * @notice The block number offset before which if the liquidity is removed, the fees will be donated to the pool.
     */
    uint256 public blockNumberOffset;

    /**
     * @dev Hook was attempted to be deployed with a block number offset that is too low.
     */
    error BlockNumberOffsetTooLow();

    /**
     * @dev Set the `PoolManager` address and the block number offset.
     */
    constructor(IPoolManager _poolManager, uint256 _blockNumberOffset) BaseHook(_poolManager) {
        if (_blockNumberOffset < MIN_BLOCK_NUMBER_OFFSET) revert BlockNumberOffsetTooLow();
        blockNumberOffset = _blockNumberOffset;
    }

    /**
     * @dev Hooks into the `afterAddLiquidity` hook to record the block number when the liquidity was added to track
     * JIT liquidity positions.
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // Get the position key
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        // Record the block number when the liquidity was added
        _lastAddedLiquidity[key.toId()][positionKey] = block.number;

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev Hooks into the `afterRemoveLiquidity` hook to donate accumulated fees for a JIT liquidity position created.
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();

        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        uint128 liquidity = StateLibrary.getLiquidity(poolManager, id);

        // We need to check if the liquidity is greater than 0 to prevent donating when there are no liquidity positions.
        if (block.number - _lastAddedLiquidity[id][positionKey] < blockNumberOffset && liquidity > 0) {
            // If the liquidity provider removes liquidity before the block number offset, the hook donates
            // the fees to the pool (i.e., in range liquidity providers at the time of liquidity removal).


            (BalanceDelta amountToDonate, BalanceDelta amountToReturn) = _getAmounts(feeDelta, id, positionKey);

            _donateToPool(key, amountToDonate);
            //BalanceDelta deltaSender = toBalanceDelta(-deltaHook.amount0(), -deltaHook.amount1());
            return (this.afterRemoveLiquidity.selector, amountToReturn);
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _calculateFeeDistribution(BalanceDelta feeDelta, PoolId id, bytes32 positionKey) internal virtual returns (BalanceDelta amountToDonate, BalanceDelta amountToReturn) {
        int128 amount0FeeDelta = feeDelta.amount0();
        int128 amount1FeeDelta = feeDelta.amount1();

        // amount0 and amount1 are necesseraly greater than 0, since they are fee rewards
        uint256 amount0Donate = FullMath.mulDiv(uint256(int256(amount0FeeDelta)), block.number - _lastAddedLiquidity[id][positionKey], blockNumberOffset);
        uint256 amount1Donate = FullMath.mulDiv(uint256(int256(amount1FeeDelta)), block.number - _lastAddedLiquidity[id][positionKey], blockNumberOffset);

        amountToDonate = toBalanceDelta(int128(int256(amount0Donate)), int128(int256(amount1Donate)));

        amountToReturn = feeDelta - amountToDonate;
    }

    /**
     * @dev Donates an amount of fees accrued to in range liquidity positions.
     *
     * @param key The key of the pool.
     * @param donation The `BalanceDelta` of the fees from the position.
     * @return delta The `BalanceDelta` of the donation.
     */
    function _donateToPool(PoolKey calldata key, BalanceDelta donation) internal returns (BalanceDelta delta) {
        // Get token amounts from the delta
        int128 amount0 = donation.amount0();
        int128 amount1 = donation.amount1();

        // Take tokens
        _takeFromPoolManager(key.currency0, amount0);
        _takeFromPoolManager(key.currency1, amount1);

        // Donate tokens
        delta = poolManager.donate(key, uint256(int256(amount0)), uint256(int256(amount1)), "");

        // Settle tokens
        _settleOnPoolManager(key.currency0, amount0);
        _settleOnPoolManager(key.currency1, amount1);
    }

    /**
     * @dev Takes `amount` of `currency` from the `PoolManager`.
     *
     * @param currency The currency from which to take the amount.
     * @param amount The amount to take.
     */
    function _takeFromPoolManager(Currency currency, int128 amount) internal {
        currency.take(poolManager, address(this), uint256(int256(amount)), true);
    }

    /**
     * @dev Settles the `amount` of `currency` on the `PoolManager`.
     *
     * @param currency The currency to settle.
     * @param amount The amount to settle.
     */
    function _settleOnPoolManager(Currency currency, int128 amount) internal {
        currency.settle(poolManager, address(this), uint256(int256(amount)), true);
    }

    /**
     * Set the hooks permissions, specifically `afterAddLiquidity`, `afterRemoveLiquidity` and `afterRemoveLiquidityReturnDelta`.
     *
     * @return permissions The permissions for the hook.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }
}
