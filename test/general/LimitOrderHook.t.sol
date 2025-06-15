// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {console} from "forge-std/console.sol";

contract LimitOrderHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    LimitOrderHook hook;

    PoolKey noHookKey;

    address user = makeAddr("user");
    address swapper = makeAddr("swapper");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHook(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

        deployCodeTo("src/general/LimitOrderHook.sol:LimitOrderHook", abi.encode(manager), address(hook));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(user, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(user, 1e30);
        IERC20Minimal(Currency.unwrap(currency0)).transfer(swapper, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(swapper, 1e30);

        vm.startPrank(user);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(swapper);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function calculateExpectedFees(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (int128, int128) {
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            StateLibrary.getPositionInfo(manager, poolId, positionKey);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            StateLibrary.getFeeGrowthInside(manager, poolId, tickLower, tickUpper);

        uint256 feesExpected0 =
            FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
        uint256 feesExpected1 =
            FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);

        return (int128(int256(feesExpected0)), int128(int256(feesExpected1)));
    }

    function modifyPoolLiquidity(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes32 salt
    ) internal returns (BalanceDelta) {
        ModifyLiquidityParams memory modifyLiquidityParams =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: salt});
        return modifyLiquidityRouter.modifyLiquidity(poolKey, modifyLiquidityParams, "");
    }

    function swapOnPool(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // Helpers
    function getCurrentTick(PoolId poolId) public view returns (int24 tick) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function test_getTickLowerLast() public view {
        assertEq(hook.getTickLowerLast(key.toId()), 0);
    }

    function test_orderIdNext() public view {
        assertTrue(OrderIdLibrary.equals(hook.orderIdNext(), OrderIdLibrary.OrderId.wrap(1)));
    }

    function test_zeroLiquidityRevert() public {
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.placeOrder(key, 0, true, 0);
    }

    function test_zeroForOneRightBoundaryOfCurrentRange() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_zeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_zeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.placeOrder(key, -60, true, 1000000);
    }

    function test_zeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.placeOrder(key, 0, true, 1000000);
    }

    function test_notZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = -60;
        bool zeroForOne = false;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_notZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.placeOrder(key, 0, false, 1000000);
    }

    function test_notZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.placeOrder(key, -60, false, 1000000);
    }

    function test_multipleLPs() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        vm.startPrank(user);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity * 2);

        (
            bool filled,
            Currency orderCurrency0,
            Currency orderCurrency1,
            uint256 currency0Total,
            uint256 currency1Total,
            uint128 liquidityTotal
        ) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));
        assertFalse(filled);
        assertTrue(currency0 == orderCurrency0);
        assertTrue(currency1 == orderCurrency1);
        assertEq(currency0Total, 0);
        assertEq(currency1Total, 0);
        assertEq(liquidityTotal, liquidity * 2);
        assertEq(hook.getOrderLiquidity(OrderIdLibrary.OrderId.wrap(1), address(this)), liquidity);
        assertEq(hook.getOrderLiquidity(OrderIdLibrary.OrderId.wrap(1), user), liquidity);
    }

    function test_cancelOrder() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        uint256 balanceBefore = currency0.balanceOf(address(this));

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        hook.cancelOrder(key, tickLower, zeroForOne, address(this));

        uint256 balanceAfterCancel = currency0.balanceOf(address(this));

        assertApproxEqAbs(balanceBefore, balanceAfterCancel, 1);
    }

    function test_cancelOrder_feesAccrued() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        //place order is the same as add liquidity to the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // add liquidity equivalent to two orders
        modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
        vm.stopPrank();

        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        vm.stopPrank();

        (bool filled,,, uint256 currency0Total, uint256 currency1Total, uint128 liquidityTotal) =
            hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");
        assertEq(liquidityTotal, 2 * liquidity, "liquidityTotal should be 2*liquidity");

        int256 balance0Before = int256(currency0.balanceOf(address(this)));
        int256 balance1Before = int256(currency1.balanceOf(address(this)));
        hook.cancelOrder(key, 0, zeroForOne, address(this));
        int256 balance0AfterCancel = int256(currency0.balanceOf(address(this)));
        int256 balance1AfterCancel = int256(currency1.balanceOf(address(this)));

        // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), 0, key.tickSpacing, 0);
        BalanceDelta delta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertEq(currency0Total, uint256(uint128(feesExpected0)));
        assertEq(currency1Total, uint256(uint128(feesExpected1)));

        assertTrue(feesExpected0 > 0 || feesExpected1 > 0);

        // canceling the order is the same as removing liquidity, minus the fees accrued to the order (which are in currency total)
        assertEq(balance0AfterCancel - balance0Before, int256(delta.amount0()) - int256(currency0Total));
        assertEq(balance1AfterCancel - balance1Before, int256(delta.amount1()) - int256(currency1Total));
    }

    function test_placeOrder_feesAccrued() public {
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        //place order is the same as add liquidity to the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // add liquidity equivalent to two orders
        modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(2*liquidity)), 0);
        vm.stopPrank();


        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        // swap outside of the range (0, tickSpacing) without filling the order to be able to place orders again
        swapOnPool(noHookKey, true, -1e15, TickMath.getSqrtPriceAtTick(-key.tickSpacing));
        swapOnPool(key, true, -1e15, TickMath.getSqrtPriceAtTick(-key.tickSpacing));
        

        vm.stopPrank();

        (bool filled,,, uint256 currency0Total, uint256 currency1Total, uint128 liquidityTotal) =
            hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");
        assertEq(liquidityTotal, 2 * liquidity, "liquidityTotal should be 2*liquidity");

        int256 balance0Before = int256(currency0.balanceOf(address(this)));
        int256 balance1Before = int256(currency1.balanceOf(address(this)));
        hook.placeOrder(key, 0, zeroForOne, liquidity);
        int256 balance0AfterPlace = int256(currency0.balanceOf(address(this)));
        int256 balance1AfterPlace = int256(currency1.balanceOf(address(this)));

        // place the order is the same as add liquidity to the pool in the range (0, tickSpacing)
        

        vm.startPrank(user);
            (int128 feesExpected0, int128 feesExpected1) =
                calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), 0, key.tickSpacing, 0);
            BalanceDelta delta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(liquidity)), 0);
        vm.stopPrank();
        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(liquidityTotal, 3 * liquidity, "liquidityTotal should be 3*liquidity");

        assertEq(currency0Total, uint256(uint128(feesExpected0)), "currency0Total should be feesExpected0");
        assertEq(currency1Total, uint256(uint128(feesExpected1)), "currency1Total should be feesExpected1");

        // canceling the order is the same as removing liquidity, minus the fees accrued to the order (which are in currency total)
        // assertEq(balance0AfterPlace - balance0Before, int256(delta.amount0()) - int256(currency0Total), "fees were not held in currency0Total");
        // assertEq(balance1AfterPlace - balance1Before, int256(delta.amount1()) - int256(currency1Total), "fees were not held in currency1Total");
    }

    function test_withdraw_multipleLPs() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        currency0.transfer(user, 1e18);
        currency1.transfer(user, 1e18);

        vm.startPrank(user);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity * 2);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + key.tickSpacing)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        (bool filled,,, uint256 currency0Total, uint256 currency1Total,) =
            hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 2 * (2996 + 17), "wrong amount of currency1");

        vm.startPrank(user);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total,) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 2996 + 17, "wrong amount of currency1");

        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

        (filled,,, currency0Total, currency1Total,) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 0, "wrong amount of currency1");
    }

    function test_swapAcrossRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        int24 tickLowerLast = hook.getTickLowerLast(key.toId());
        int24 currentTick = getCurrentTick(key.toId());

        assertEq(currentTick, tickLower, "Initial tick is wrong");

        console.log("initial tick", currentTick);
        console.log("tick spacing", key.tickSpacing);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower - 10 * key.tickSpacing)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        console.log("tick after swap 1", currentTick = getCurrentTick(key.toId()));

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + key.tickSpacing / 2)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        console.log("tick after swap 2", currentTick = getCurrentTick(key.toId()));

        //assertEq(hook.getTickLowerLast(key.toId()), tickLower + key.tickSpacing);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        //assertEq(tick, tickLower + key.tickSpacing);

        (bool filled,,, uint256 currency0Total, uint256 currency1Total,) =
            hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower - key.tickSpacing / 2)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        console.log("tick after swap 1", currentTick = getCurrentTick(key.toId()));

        (filled,,, currency0Total, currency1Total,) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 2996 + 17, "wrong amount of currency1"); // 3013, 2 wei of dust

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), 0);

        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

        (,,, uint256 currency0Amount, uint256 currency1Amount,) = hook.orderInfos(OrderIdLibrary.OrderId.wrap(1));
        assertEq(currency0Amount, 0);
        assertEq(currency1Amount, 0);
    }
}
