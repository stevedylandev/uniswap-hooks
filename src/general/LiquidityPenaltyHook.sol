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
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta, eq} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @dev Just-in-Time (JIT) liquidity provisioning resistant hook.
 *
 * This hook disincentivizes JIT attacks by penalizing LP fee collection during `afterRemoveLiquidity`,
 * and disabling it during `afterAddLiquidity` if liquidity was recently added to the position.
 * The penalty is donated to the pool's liquidity providers in range at the time of removal.
 *
 * See {_calculateLiquidityPenalty} for penalty calculation.
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
     * @dev The hook was attempted to be constructed with a `blockNumberOffset` lower than `MIN_BLOCK_NUMBER_OFFSET`.
     */
    error BlockNumberOffsetTooLow();

    /**
     * @dev The minimum number of blocks for the `blockNumberOffset`.
     */
    uint48 public constant MIN_BLOCK_NUMBER_OFFSET = 1;

    /**
     * @dev The minimum time window (in blocks) that must pass after adding liquidity before it can be
     * removed without penalty. During this period, JIT attacks are deterred through fee withholding
     * and penalties. Higher values provide stronger JIT protection but may discourage legitimate LPs.
     */
    uint48 private immutable _blockNumberOffset;

    /**
     * @dev Tracks the last block during which liquidity was added to a position.
     */
    mapping(PoolId poolId => mapping(bytes32 positionKey => uint48 blockNumber)) private _lastAddedLiquidityBlock;

    /**
     * @dev Tracks the `withheldFeesAccrued` for a liquidity position.
     *
     * `withheldFeesAccrued` are UniswapV4's `feesAccrued` retained by this hook during liquidity addition if liquidity
     * has been added within the `blockNumberOffset` period. See {_afterRemoveLiquidity} for claiming the fees back.
     *
     * This effectively disables fee collection during JIT liquidity provisioning.
     */
    mapping(PoolId poolId => mapping(bytes32 positionKey => BalanceDelta delta)) private _withheldFeesAccrued;

    /**
     * @dev Sets the `PoolManager` address and the `blockNumberOffset`.
     */
    constructor(IPoolManager poolManager_, uint48 blockNumberOffset_) BaseHook(poolManager_) {
        if (blockNumberOffset_ < MIN_BLOCK_NUMBER_OFFSET) revert BlockNumberOffsetTooLow();
        _blockNumberOffset = blockNumberOffset_;
    }

    /**
     * @dev Tracks `lastAddedLiquidityBlock` and withholds `feesAccrued` if liquidity was added within the `blockNumberOffset` period.
     * See {_afterRemoveLiquidity} for claiming the withheld fees back.
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta, /* delta */
        BalanceDelta feeDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        // If liquidity was added recently within the `blockNumberOffset`, retain the `feesAccrued` in this hook.
        if (_getBlockNumber() - getLastAddedLiquidityBlock(poolId, positionKey) < getBlockNumberOffset()) {
            _updateLastAddedLiquidityBlock(poolId, positionKey);
            _takeFeesToHook(key, positionKey, feeDelta);

            return (this.afterAddLiquidity.selector, feeDelta);
        }

        _updateLastAddedLiquidityBlock(poolId, positionKey);

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev Penalizes the collection of LP `feesAccrued` after liquidity removal if liquidity was recently added to the position.
     *
     * NOTE: The penalty is applied on both `withheldFees` and the current `feeDelta` equally.
     * Therefore, regardless of how many times liquidity was added to the position within the `blockNumberOffset` period,
     * all accrued fees are penalized as if the liquidity was added only once during that period. This ensures that splitting
     * liquidity additions within the `blockNumberOffset` period does not reduce or increase the penalty.
     *
     * IMPORTANT: The penalty is donated to the pool's liquidity providers in range at the time of liquidity removal,
     * which may be different from the liquidity providers in range at the time of liquidity addition.
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta, /* delta */
        BalanceDelta feeDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        // Receive back the `withheldFeesAccrued` retained during previous liquidity additions within the `blockNumberOffset`.
        BalanceDelta withheldFees = _settleFeesFromHook(key, positionKey);

        // We need to ensure the liquidity is greater than 0 to prevent donating when there are no liquidity positions,
        // otherwise the PoolManager would revert and block the removal of liquidity.
        uint128 liquidity = poolManager.getLiquidity(poolId);

        if (
            _getBlockNumber() - getLastAddedLiquidityBlock(poolId, positionKey) < getBlockNumberOffset()
                && liquidity > 0
        ) {
            // The total fees accrued by the LP are the sum of the current `feeDelta` plus the potentially withheldFees.
            BalanceDelta liquidityPenalty = _calculateLiquidityPenalty(feeDelta + withheldFees, key.toId(), positionKey);

            poolManager.donate(
                key, uint256(int256(liquidityPenalty.amount0())), uint256(int256(liquidityPenalty.amount1())), ""
            );

            return (this.afterRemoveLiquidity.selector, liquidityPenalty - withheldFees);
        }

        // If the liquidity removal was not penalized, return the withheld fees if any.
        if (withheldFees != BalanceDeltaLibrary.ZERO_DELTA) {
            BalanceDelta returnDelta = toBalanceDelta(-withheldFees.amount0(), -withheldFees.amount1());
            return (this.afterRemoveLiquidity.selector, returnDelta);
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev Returns the current block number.
     */
    function _getBlockNumber() internal view virtual returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @dev Updates the `lastAddedLiquidityBlock` for a liquidity position.
     */
    function _updateLastAddedLiquidityBlock(PoolId poolId, bytes32 positionKey) internal virtual {
        _lastAddedLiquidityBlock[poolId][positionKey] = _getBlockNumber();
    }

    /**
     * @dev Takes `feeDelta` from a liquidity position as `withheldFeesAccrued` into this hook.
     */
    function _takeFeesToHook(PoolKey calldata key, bytes32 positionKey, BalanceDelta feeDelta) internal {
        PoolId poolId = key.toId();

        _withheldFeesAccrued[poolId][positionKey] = _withheldFeesAccrued[poolId][positionKey] + feeDelta;

        key.currency0.take(poolManager, address(this), uint256(uint128(feeDelta.amount0())), true);
        key.currency1.take(poolManager, address(this), uint256(uint128(feeDelta.amount1())), true);
    }

    /**
     * @dev Returns `withheldFeesAccrued` from this hook to the liquidity provider.
     */
    function _settleFeesFromHook(PoolKey calldata key, bytes32 positionKey)
        internal
        returns (BalanceDelta withheldFees)
    {
        PoolId poolId = key.toId();

        withheldFees = getWithheldFees(poolId, positionKey);

        // Reset the `withheldFeesAccrued`.
        _withheldFeesAccrued[poolId][positionKey] = BalanceDeltaLibrary.ZERO_DELTA;

        // Settle the `withheldFeesAccrued` for the liquidity position.
        if (withheldFees.amount0() > 0) {
            key.currency0.settle(poolManager, address(this), uint256(uint128(withheldFees.amount0())), true);
        }
        if (withheldFees.amount1() > 0) {
            key.currency1.settle(poolManager, address(this), uint256(uint128(withheldFees.amount1())), true);
        }
    }

    /**
     * @dev Calculates the penalty to be applied to JIT liquidity provisioning.
     *
     * The penalty is calculated as a linear function of the block number difference between the `lastAddedLiquidityBlock` and the `currentBlockNumber`.
     *
     * The formula is:
     * liquidityPenalty = feeDelta * ( 1 - (currentBlockNumber - lastAddedLiquidityBlock) / blockNumberOffset)
     *
     * The penalty is 100% at the block where liquidity was last added and 0% after the `blockNumberOffset` block.
     *
     * NOTE: This function is called only if the liquidity is removed before the `blockNumberOffset`, i.e.,
     * (currentBlockNumber - lastAddedLiquidityBlock) < blockNumberOffset, so the subtraction is safe and won't overflow.
     */
    function _calculateLiquidityPenalty(BalanceDelta feeDelta, PoolId poolId, bytes32 positionKey)
        internal
        virtual
        returns (BalanceDelta liquidityPenalty)
    {
        uint48 currentBlockNumber = _getBlockNumber();
        uint48 lastAddedLiquidityBlock = getLastAddedLiquidityBlock(poolId, positionKey);
        uint48 blockNumberOffset = getBlockNumberOffset();

        // Note that `amount0` and `amount1` are necessarily greater than or equal to 0, since they are fee rewards.
        (int128 amount0FeeDelta, int128 amount1FeeDelta) = (feeDelta.amount0(), feeDelta.amount1());

        unchecked {
            uint256 amount0LiquidityPenalty = FullMath.mulDiv(
                SafeCast.toUint128(amount0FeeDelta),
                blockNumberOffset - (currentBlockNumber - lastAddedLiquidityBlock), // won't overflow.
                blockNumberOffset
            );
            uint256 amount1LiquidityPenalty = FullMath.mulDiv(
                SafeCast.toUint128(amount1FeeDelta),
                blockNumberOffset - (currentBlockNumber - lastAddedLiquidityBlock), // won't overflow.
                blockNumberOffset
            );

            // Although the amounts are returned as uint256, they must fit in int128, since they are fee rewards.
            liquidityPenalty = toBalanceDelta(amount0LiquidityPenalty.toInt128(), amount1LiquidityPenalty.toInt128());
        }
    }

    /**
     * @dev Returns the `blockNumberOffset`.
     */
    function getBlockNumberOffset() public view returns (uint48) {
        return _blockNumberOffset;
    }

    /**
     * @dev Returns the `lastAddedLiquidityBlock` for a liquidity position.
     */
    function getLastAddedLiquidityBlock(PoolId poolId, bytes32 positionKey) public view virtual returns (uint48) {
        return _lastAddedLiquidityBlock[poolId][positionKey];
    }

    /**
     * @dev Returns the `withheldFeesAccrued` for a liquidity position.
     */
    function getWithheldFees(PoolId poolId, bytes32 positionKey) public view returns (BalanceDelta) {
        return _withheldFeesAccrued[poolId][positionKey];
    }

    /**
     * @dev Set the hooks permissions, specifically `afterAddLiquidity`, `afterAddLiquidityReturnDelta`, `afterRemoveLiquidity` and `afterRemoveLiquidityReturnDelta`.
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
