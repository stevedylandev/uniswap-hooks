// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {AntiJITHook} from "src/general/AntiJITHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {console} from "forge-std/console.sol";

contract AntiJITHookTest is Test, Deployers {
    AntiJITHook hook;
    PoolKey noHookKey;
    uint24 fee = 1000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = AntiJITHook(
            address(uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG))
        );
        deployCodeTo("src/general/AntiJITHook.sol:AntiJITHook", abi.encode(manager, 1), address(hook));

        (key,) = initPool(
            currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1
        );
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_addLiquidity_noSwap() public {

        IPoolManager.ModifyLiquidityParams memory addLiquidityParams  = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, 
            tickUpper: 600, 
            liquidityDelta: 1e18, 
            salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(key, addLiquidityParams, "");
        modifyLiquidityRouter.modifyLiquidity(noHookKey, addLiquidityParams, "");

        IPoolManager.ModifyLiquidityParams memory removeLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, 
            tickUpper: 600, 
            liquidityDelta: -1e17, 
            salt: 0
        });

        BalanceDelta deltaHook = modifyLiquidityRouter.modifyLiquidity(key, removeLiquidityParams, "");
        BalanceDelta deltaNoHook = modifyLiquidityRouter.modifyLiquidity(noHookKey, removeLiquidityParams, "");

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));

    }

        function test_addLiquidity_SwapZeroForOne() public {

        IPoolManager.ModifyLiquidityParams memory addLiquidityParams  = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, 
            tickUpper: 600, 
            liquidityDelta: 1e18, 
            salt: 0
        });


        modifyLiquidityRouter.modifyLiquidity(key, addLiquidityParams, "");
        modifyLiquidityRouter.modifyLiquidity(noHookKey, addLiquidityParams, "");

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1e15,
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        IPoolManager.ModifyLiquidityParams memory removeLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, 
            tickUpper: 600, 
            liquidityDelta: -1e17, 
            salt: 0
        });

        BalanceDelta deltaHook = modifyLiquidityRouter.modifyLiquidity(key, removeLiquidityParams, "");
        BalanceDelta deltaNoHook = modifyLiquidityRouter.modifyLiquidity(noHookKey, removeLiquidityParams, "");

        console.log("deltaNoHook", BalanceDeltaLibrary.amount0(deltaNoHook));
        console.log("deltaHook", BalanceDeltaLibrary.amount0(deltaHook));

        console.log("delta no hook amount 1", BalanceDeltaLibrary.amount1(deltaNoHook));
        console.log("delta hook amount 1", BalanceDeltaLibrary.amount1(deltaHook));


        int128 feeExpected = int128(uint128(fee));
        int128 expectedAmount1 = BalanceDeltaLibrary.amount1(deltaNoHook) - 1e15*feeExpected/1000000;

        console.log("expected amount 1", expectedAmount1);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), expectedAmount1);


    }
}