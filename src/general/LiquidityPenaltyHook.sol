// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.1) (src/general/LiquidityPenaltyHook.sol)

pragma solidity ^0.8.24;

// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

// External imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @dev This hook implements a mechanism penalize liquidity provision based on time of adding and removal of liquidty.
 * The main purpose is to prevent JIT (Just in Time) attacks on liquidity pools. Specifically,
 * it checks if a liquidity position was added to the pool within a certain block number range (at least 1 block)
 * and if so, it donates some of the fees to the pool (up to 100% of the fees). This way, the hook effectively taxes JIT attackers by donating their
 * expected profits back to the pool.
 * The hook calculates the fee donation based on the block number when the liquidity was added
 * and the block number offset.
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
contract LiquidityPenaltyHook is BaseHook {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /**
     * @notice The minimum block number amount for the offset.
     */
    uint256 public constant MIN_BLOCK_NUMBER_OFFSET = 1;

    /**
     * @notice Tracks the last block number when a liquidity position was added to the pool.
     */
    mapping(PoolId id => mapping(bytes32 positionKey => uint256 blockNumber)) private lastAddedLiquidity;

    mapping(PoolId id => mapping(bytes32 positionKey => BalanceDelta delta)) private pendingFeesAccrued;

    /**
     * @notice The block number offset before which if the liquidity is removed, the fees will be donated to the pool.
     */
    uint256 private immutable blockNumberOffset;

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
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        // Get the position key
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        uint128 liquidity = poolManager.getLiquidity(id);
        // We need to check if the liquidity is greater than 0 to prevent donating when there are no liquidity positions.
        if (block.number - lastAddedLiquidity[id][positionKey] < blockNumberOffset && liquidity > 0) {
            // store the block number when the liquidity was added
            lastAddedLiquidity[id][positionKey] = block.number;

            key.currency0.take(poolManager, address(this), uint256(uint128(feeDelta.amount0())), true);
            key.currency1.take(poolManager, address(this), uint256(uint128(feeDelta.amount1())), true);

            pendingFeesAccrued[id][positionKey] = pendingFeesAccrued[id][positionKey] + feeDelta;

            return (this.afterAddLiquidity.selector, feeDelta);
        }

        // store the block number when the liquidity was added
        lastAddedLiquidity[id][positionKey] = block.number;

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev Hooks into the `afterRemoveLiquidity` hook to donate accumulated fees for a JIT liquidity position created.
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        uint128 liquidity = poolManager.getLiquidity(key.toId());

        BalanceDelta pendingFees = _settlePendingFees(key, positionKey);

        // We need to check if the liquidity is greater than 0 to prevent donating when there are no liquidity positions.
        if (block.number - lastAddedLiquidity[key.toId()][positionKey] < blockNumberOffset && liquidity > 0) {
            // If the liquidity provider removes liquidity before the block number offset, the hook donates
            // a part of the fees to the pool (i.e., in range liquidity providers at the time of liquidity removal).
            BalanceDelta totalFeesAccrued = feeDelta + pendingFees;

            BalanceDelta liquidityPenalty = _calculateLiquidityPenalty(totalFeesAccrued, key.toId(), positionKey);

            BalanceDelta deltaHook = poolManager.donate(
                key, uint256(int256(liquidityPenalty.amount0())), uint256(int256(liquidityPenalty.amount1())), ""
            );

            BalanceDelta returnDelta = toBalanceDelta(-deltaHook.amount0(), -deltaHook.amount1());

            return (this.afterRemoveLiquidity.selector, returnDelta);
        }

        if (pendingFees != BalanceDeltaLibrary.ZERO_DELTA) {
            BalanceDelta returnDelta = toBalanceDelta(-pendingFees.amount0(), -pendingFees.amount1());
            return (this.afterRemoveLiquidity.selector, returnDelta);
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function getPendingFees(PoolId id, bytes32 positionKey) public view returns (BalanceDelta) {
        return pendingFeesAccrued[id][positionKey];
    }

    function _settlePendingFees(PoolKey calldata key, bytes32 positionKey) internal returns (BalanceDelta) {
        PoolId id = key.toId();
        BalanceDelta pendingFees = getPendingFees(id, positionKey);
        pendingFeesAccrued[id][positionKey] = BalanceDeltaLibrary.ZERO_DELTA;

        Currency currency0 = key.currency0;
        Currency currency1 = key.currency1;

        currency0.settle(poolManager, address(this), uint256(uint128(pendingFees.amount0())), true);
        currency1.settle(poolManager, address(this), uint256(uint128(pendingFees.amount1())), true);

        return pendingFees;
    }

    /**
     * @dev Calculates the fee donation when a liquidity position is removed before the block number offset.
     *
     * @param feeDelta The `BalanceDelta` of the fees from the position.
     * @param poolId The `PoolId` of the pool.
     * @param positionKey The `bytes32` key of the position.
     * @return liquidityPenalty The `BalanceDelta` of the liquidity penalty.
     */
    function _calculateLiquidityPenalty(BalanceDelta feeDelta, PoolId poolId, bytes32 positionKey)
        internal
        virtual
        returns (BalanceDelta liquidityPenalty)
    {
        int128 amount0FeeDelta = feeDelta.amount0();
        int128 amount1FeeDelta = feeDelta.amount1();

        // amount0 and amount1 are necesseraly greater than or equal to 0, since they are fee rewards
        // This is the implementation of a linear penalty on the fees, where the penalty decreases linearly from 100% of the fees at the block
        // where liquidity was added to the pool to 0% after the block number offset.
        // The formula is:
        // liquidityPenalty = feeDelta * ( 1 - (block.number - lastAddedLiquidity[id][positionKey]) / blockNumberOffset)
        // NOTE: this function is called only if the liquidity is removed before the block number offset, i.e.,
        // block.number - lastAddedLiquidity[poolId][positionKey] < blockNumberOffset
        // so the subtraction is safe and won't overflow
        uint256 amount0LiquidityPenalty = FullMath.mulDiv(
            SafeCast.toUint128(amount0FeeDelta),
            blockNumberOffset - (block.number - lastAddedLiquidity[poolId][positionKey]), // wont't overflow, since block.number - lastAddedLiquidity[poolId][positionKey] < blockNumberOffset
            blockNumberOffset
        );
        uint256 amount1LiquidityPenalty = FullMath.mulDiv(
            SafeCast.toUint128(amount1FeeDelta),
            blockNumberOffset - (block.number - lastAddedLiquidity[poolId][positionKey]),
            blockNumberOffset
        );

        // although the amounts are returned as uint256, they must fit in int128, since they are fee rewards
        liquidityPenalty = toBalanceDelta(amount0LiquidityPenalty.toInt128(), amount1LiquidityPenalty.toInt128());
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
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }
}
