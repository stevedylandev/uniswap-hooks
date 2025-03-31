// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/general/LimitOrderHook.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {console} from "forge-std/console.sol";

type Epoch is uint232;

library EpochLibrary {
    function equals(Epoch a, Epoch b) internal pure returns (bool) {
        return Epoch.unwrap(a) == Epoch.unwrap(b);
    }

    function unsafeIncrement(Epoch a) internal pure returns (Epoch) {
        unchecked {
            return Epoch.wrap(Epoch.unwrap(a) + 1);
        }
    }
}

contract LimitOrderHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using EpochLibrary for Epoch;

    using CurrencySettler for Currency;

    error ZeroLiquidity();
    error InRange();
    error CrossedRange();
    error AlreadyInitialized();
    error Filled();
    error NotFilled();

    event Place(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    event Fill(Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne);

    event Kill(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    event Withdraw(address indexed owner, Epoch indexed epoch, uint128 liquidity);

    bytes internal constant ZERO_BYTES = bytes("");

    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);

    struct EpochInfo {
        bool filled;
        Currency currency0;
        Currency currency1;
        uint256 currency0Total;
        uint256 currency1Total;
        uint128 liquidityTotal;
        mapping(address => uint128) liquidity;
    }

    mapping(PoolId => int24) public tickLowerLasts;

    Epoch public epochNext = Epoch.wrap(1);

    mapping(bytes32 => Epoch) public epochs;
    mapping(Epoch => EpochInfo) public epochInfos;

    enum Callbacks {
        Place,
        Kill,
        Withdraw
    }

    struct CallbackData {
        Callbacks callbackType;
        bytes data;
    }

    struct CallbackDataPlace {
        PoolKey key;
        address owner;
        bool zeroForOne;
        int24 tickLower;
        uint128 liquidity;
    }

    struct CallbackDataKill {
        PoolKey key;
        int24 tickLower;
        int256 liquidityDelta;
        address to;
        bool removingAllLiquidity;
    }

    struct CallbackDataWithdraw {
        Currency currency0;
        Currency currency1;
        uint256 currency0Amount;
        uint256 currency1Amount;
        address to;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));

        return this.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(key.toId(), key.tickSpacing);

        if (lower > upper) return (this.afterSwap.selector, 0);

        // note that a zeroForOne swap means that the pool is actually gaining token0, so limit
        // order fills are the opposite of swap fills, hence the inversion below
        bool zeroForOne = !params.zeroForOne;
        for (; lower <= upper; lower += key.tickSpacing) {
            _fillEpoch(key, lower, zeroForOne);
        }

        setTickLowerLast(key.toId(), tickLower);

        return (this.afterSwap.selector, 0);
    }

    function place(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) external {
        if (liquidity == 0) revert ZeroLiquidity();

        poolManager.unlock(
            abi.encode(
                CallbackData(
                    Callbacks.Place, abi.encode(CallbackDataPlace(key, msg.sender, zeroForOne, tick, liquidity))
                )
            )
        );

        EpochInfo storage epochInfo;

        Epoch epoch = getEpoch(key, tick, zeroForOne);

        if (epoch.equals(EPOCH_DEFAULT)) {
            unchecked {
                setEpoch(key, tick, zeroForOne, epoch = epochNext);

                epochNext = epochNext.unsafeIncrement();
            }

            epochInfo = epochInfos[epoch];
            epochInfo.currency0 = key.currency0;
            epochInfo.currency1 = key.currency1;
        } else {
            epochInfo = epochInfos[epoch];
        }

        unchecked {
            epochInfo.liquidityTotal += liquidity;
            epochInfo.liquidity[msg.sender] += liquidity;
        }

        emit Place(msg.sender, epoch, key, tick, zeroForOne, liquidity);
    }

    function kill(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to) external {
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (epochInfo.filled) revert Filled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];

        if (liquidity == 0) revert ZeroLiquidity();

        delete epochInfo.liquidity[msg.sender];

        (uint256 amount0Fee, uint256 amount1Fee) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        Callbacks.Kill,
                        abi.encode(
                            CallbackDataKill(
                                key, tickLower, -int256(uint256(liquidity)), to, liquidity == epochInfo.liquidityTotal
                            )
                        )
                    )
                )
            ),
            (uint256, uint256)
        );

        epochInfo.liquidityTotal -= liquidity;

        unchecked {
            epochInfo.currency0Total += amount0Fee;
            epochInfo.currency1Total += amount1Fee;
        }

        emit Kill(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }

    function withdraw(Epoch epoch, address to) external returns (uint256 amount0, uint256 amount1) {
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (!epochInfo.filled) revert NotFilled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];

        if (liquidity == 0) revert ZeroLiquidity();

        delete epochInfo.liquidity[msg.sender];

        uint128 liquidityTotal = epochInfo.liquidityTotal;

        amount0 = FullMath.mulDiv(epochInfo.currency0Total, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(epochInfo.currency1Total, liquidity, liquidityTotal);

        epochInfo.currency0Total -= amount0;
        epochInfo.currency1Total -= amount1;

        poolManager.unlock(
            abi.encode(
                CallbackData(
                    Callbacks.Withdraw,
                    abi.encode(CallbackDataWithdraw(epochInfo.currency0, epochInfo.currency1, amount0, amount1, to))
                )
            )
        );

        emit Withdraw(msg.sender, epoch, liquidity);
    }

    function unlockCallback(bytes calldata rawData)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackData memory callbackData = abi.decode(rawData, (CallbackData));

        if (callbackData.callbackType == Callbacks.Place) {
            CallbackDataPlace memory data = abi.decode(callbackData.data, (CallbackDataPlace));

            PoolKey memory key = data.key;

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: data.tickLower,
                    tickUpper: data.tickLower + key.tickSpacing,
                    liquidityDelta: int256(uint256(data.liquidity)),
                    salt: 0
                }),
                ZERO_BYTES
            );

            if (delta.amount0() < 0) {
                if (delta.amount1() != 0) revert InRange();
                if (!data.zeroForOne) revert CrossedRange();

                key.currency0.settle(poolManager, data.owner, uint256(uint128(-delta.amount0())), false);
            } else {
                if (delta.amount0() != 0) revert InRange();
                if (data.zeroForOne) revert CrossedRange();

                key.currency1.settle(poolManager, data.owner, uint256(uint128(-delta.amount1())), false);
            }
        } else if (callbackData.callbackType == Callbacks.Kill) {
            CallbackDataKill memory data = abi.decode(callbackData.data, (CallbackDataKill));

            int24 tickUpper = data.tickLower + data.key.tickSpacing;

            uint256 amount0Fee;
            uint256 amount1Fee;

            // because `modifyPosition` includes not just principal value but also fees, we cannot allocate
            // the proceeds pro-rata. if we were to do so, users who have been in a limit order that's partially filled
            // could be unfairly diluted by a user sychronously placing then killing a limit order to skim off fees.
            // to prevent this, we allocate all fee revenue to remaining limit order placers, unless this is the last order.
            if (!data.removingAllLiquidity) {
                (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                    data.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: data.tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: 0,
                        salt: 0
                    }),
                    ZERO_BYTES
                );

                if (feesAccrued.amount0() > 0) {
                    poolManager.mint(
                        address(this), data.key.currency0.toId(), amount0Fee = uint128(feesAccrued.amount0())
                    );
                }

                if (feesAccrued.amount1() > 0) {
                    poolManager.mint(
                        address(this), data.key.currency1.toId(), amount1Fee = uint128(feesAccrued.amount1())
                    );
                }
            }

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                data.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: data.tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: data.liquidityDelta,
                    salt: 0
                }),
                ZERO_BYTES
            );

            if (delta.amount0() > 0) {
                data.key.currency0.take(poolManager, data.to, uint256(uint128(delta.amount0())), false);
            }

            if (delta.amount1() > 0) {
                data.key.currency1.take(poolManager, data.to, uint256(uint128(delta.amount1())), false);
            }

            return abi.encode(amount0Fee, amount1Fee);
        } else if (callbackData.callbackType == Callbacks.Withdraw) {
            CallbackDataWithdraw memory data = abi.decode(callbackData.data, (CallbackDataWithdraw));

            if (data.currency0Amount > 0) {
                poolManager.burn(address(this), data.currency0.toId(), data.currency0Amount);
                //data.currency0.take(poolManager, data.to, data.currency0Amount, false);
                poolManager.take(data.currency0, data.to, data.currency0Amount);
            }

            if (data.currency1Amount > 0) {
                poolManager.burn(address(this), data.currency1.toId(), data.currency1Amount);
                //data.currency1.take(poolManager, data.to, data.currency1Amount, false);
                poolManager.take(data.currency1, data.to, data.currency1Amount);
            }
        }
    }

    function _fillEpoch(PoolKey calldata key, int24 lower, bool zeroForOne) internal {
        Epoch epoch = getEpoch(key, lower, zeroForOne);
        if (!epoch.equals(EPOCH_DEFAULT)) {
            EpochInfo storage epochInfo = epochInfos[epoch];

            epochInfo.filled = true;

            uint128 amount0;
            uint128 amount1;

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: lower + key.tickSpacing,
                    liquidityDelta: -int256(uint256(epochInfo.liquidityTotal)),
                    salt: 0
                }),
                ZERO_BYTES
            );

            if (delta.amount0() > 0) {
                poolManager.mint(address(this), key.currency0.toId(), amount0 = uint128(delta.amount0()));
            }
            if (delta.amount1() > 0) {
                poolManager.mint(address(this), key.currency1.toId(), amount1 = uint128(delta.amount1()));
            }

            unchecked {
                epochInfo.currency0Total += amount0;
                epochInfo.currency1Total += amount1;
            }

            setEpoch(key, lower, zeroForOne, EPOCH_DEFAULT);

            //emit Fill(epoch, key, lower, zeroForOne);
        }
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = getTickLower(getTick(poolId), tickSpacing);
        int24 tickLowerLast = getTickLowerLast(poolId);

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    function getTickLowerLast(PoolId poolId) public view returns (int24) {
        return tickLowerLasts[poolId];
    }

    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne) public view returns (Epoch) {
        return epochs[keccak256(abi.encode(key, tickLower, zeroForOne))];
    }

    function setEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne, Epoch epoch) private {
        epochs[keccak256(abi.encode(key, tickLower, zeroForOne))] = epoch;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    function getEpochLiquidity(Epoch epoch, address owner) external view returns (uint256) {
        return epochInfos[epoch].liquidity[owner];
    }

    function getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /**
     * @dev Set the hook permissions, specifically `beforeSwap` and `beforeSwapReturnDelta`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
