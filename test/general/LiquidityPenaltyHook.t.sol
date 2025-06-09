// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LiquidityPenaltyHook} from "src/general/LiquidityPenaltyHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {HookTest} from "test/utils/HookTest.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {console} from "forge-std/console.sol";

contract LiquidityPenaltyHookTest is HookTest {
    LiquidityPenaltyHook hook;
    PoolKey noHookKey;
    uint24 fee = 1000; // 0.1%

    address bob = makeAddr("bob"); // long term LP
    address attacker = makeAddr("attacker"); // JIT attacker

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LiquidityPenaltyHook(
            address(
                uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                )
            )
        );
        deployCodeTo("src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, 1), address(hook));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_deploy_LowOffset_reverts() public {
        vm.expectRevert();
        deployCodeTo("src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, 0), address(hook));
    }

    function test_noSwaps() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // remove liquidity
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(deltaHook, deltaNoHook, "with no swaps, the behavior should be equivalent");
    }

    function test_JIT() public {}

    function test_JIT_SingleLP() public {
        bool zeroForOne = true;

        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // calculate earned fees due to the swap
        BalanceDelta hookFeeDelta =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        BalanceDelta noHookFeeDelta =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        assertEq(hookFeeDelta, noHookFeeDelta, "feeDelta should be equal between hooked and unhooked pools");

        // remove liquidity during the same block (consolidate JIT attack), expect penalty to be applied in the hooked pool
        vm.expectEmit(false, false, true, true);
        emit Donate(key.toId(), address(0), uint128(hookFeeDelta.amount0()), uint128(hookFeeDelta.amount1()));
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);
        assertEq(
            deltaHook,
            deltaNoHook - hookFeeDelta,
            "feeDelta penalty should be applied to the hooked pool during JIT attack"
        );

        // since the ataccker is the only LP, he should have been the recipient of the donation
        BalanceDelta hookFeeDeltaAfterRemoval =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        assertAproxEqAbs(
            hookFeeDeltaAfterRemoval,
            hookFeeDelta,
            1,
            "The attacker should have been the recipient of the donation since he is the only LP"
        );

        // unhooked pool should have collected the fees already during liquidity removal
        BalanceDelta noHookFeeDeltaAfterRemoval =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        assertEq(
            noHookFeeDeltaAfterRemoval, toBalanceDelta(0, 0), "Unhooked pool should have collected the fees already"
        );
    }

    function test_JIT_SingleLP_RemoveEntireLiquidity() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        uint128 liquidityHookKey = StateLibrary.getLiquidity(manager, key.toId());
        uint128 liquidityNoHookKey = StateLibrary.getLiquidity(manager, noHookKey.toId());

        // remove entire liquidity
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -int128(liquidityHookKey), 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -int128(liquidityNoHookKey), 0);

        assertEq(deltaHook, deltaNoHook, "Penalty should not be applied when removing the entire liquidity");
    }

    function test_addLiquidity_Swap_addLiquidityJIT() public {
        bool zeroForOne = true;

        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        // add liquidity
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, 1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, 1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feesExpected0);
        assertEq(-BalanceDeltaLibrary.amount1(deltaHook), -BalanceDeltaLibrary.amount1(deltaNoHook) + feesExpected1);

        uint256 hookClaims0 = manager.balanceOf(address(key.hooks), currency0.toId());
        uint256 hookClaims1 = manager.balanceOf(address(key.hooks), currency1.toId());

        assertEq(hookClaims0, uint256(uint128(feesExpected0)));
        assertEq(hookClaims1, uint256(uint128(feesExpected1)));

        vm.roll(block.number + 1);
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        uint128 liquidityHookKey = StateLibrary.getLiquidity(manager, key.toId());
        uint128 liquidityNoHookKey = StateLibrary.getLiquidity(manager, noHookKey.toId());

        assertEq(liquidityHookKey, liquidityNoHookKey);

        BalanceDelta deltaHookNextBlock = modifyPoolLiquidity(key, -600, 600, -int128(liquidityHookKey), 0);
        BalanceDelta deltaNoHookNextBlock = modifyPoolLiquidity(noHookKey, -600, 600, -int128(liquidityNoHookKey), 0);

        uint256 hookClaims0NextBlock = manager.balanceOf(address(key.hooks), currency0.toId());
        uint256 hookClaims1NextBlock = manager.balanceOf(address(key.hooks), currency1.toId());

        assertEq(hookClaims0NextBlock, 0);
        assertEq(hookClaims1NextBlock, 0);

        assertEq(
            BalanceDeltaLibrary.amount0(deltaHookNextBlock),
            BalanceDeltaLibrary.amount0(deltaNoHookNextBlock) + feesExpected0
        );
        assertEq(
            BalanceDeltaLibrary.amount1(deltaHookNextBlock),
            BalanceDeltaLibrary.amount1(deltaNoHookNextBlock) + feesExpected1
        );
    }

    function test_addLiquidityMultiple_removeNextBlock() public {
        bool zeroForOne = true;

        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // add 0 liquidity to both pools, the pool with the hook should not have any claims
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, 0, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, 0, 0);

        uint256 hookClaims0 = manager.balanceOf(address(key.hooks), currency0.toId());
        uint256 hookClaims1 = manager.balanceOf(address(key.hooks), currency1.toId());

        assertEq(hookClaims0, uint256(uint128(deltaHook.amount0())));
        assertEq(hookClaims1, uint256(uint128(deltaHook.amount1())));

        assertEq(deltaHook.amount0(), 0);
        assertEq(deltaHook.amount1(), 0);

        vm.roll(block.number + 1);

        // add 0 liquidity to the pool with the hook, fees should be claimed by LP
        BalanceDelta deltaHookAdd = modifyPoolLiquidity(key, -600, 600, 0, 0);

        uint256 hookClaims0NextBlock = manager.balanceOf(address(key.hooks), currency0.toId());
        uint256 hookClaims1NextBlock = manager.balanceOf(address(key.hooks), currency1.toId());

        assertEq(hookClaims0NextBlock, 0);
        assertEq(hookClaims1NextBlock, 0);

        // add approx with 1 due to rounding differences
        assertApproxEqAbs(deltaHookAdd.amount0(), deltaNoHook.amount0(), 1);
        assertApproxEqAbs(deltaHookAdd.amount1(), deltaNoHook.amount1(), 1);
    }

    function test_addLiquidity_MultipleSwaps_JIT() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams1 = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        SwapParams memory swapParams2 = SwapParams({
            zeroForOne: false,
            amountSpecified: 1e15, //exact output
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        SwapParams memory swapParams3 = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        SwapParams memory swapParams4 = SwapParams({
            zeroForOne: true,
            amountSpecified: 1e15, //exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams1, testSettings, "");
        swapRouter.swap(key, swapParams2, testSettings, "");
        swapRouter.swap(key, swapParams3, testSettings, "");
        swapRouter.swap(key, swapParams4, testSettings, "");

        swapRouter.swap(noHookKey, swapParams1, testSettings, "");
        swapRouter.swap(noHookKey, swapParams2, testSettings, "");
        swapRouter.swap(noHookKey, swapParams3, testSettings, "");
        swapRouter.swap(noHookKey, swapParams4, testSettings, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feesExpected0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feesExpected1);
    }

    function test_addLiquidity_RemoveNextBlock() public {
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        vm.roll(block.number + 1);
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function test_donateToPool_JIT() public {
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        donateRouter.donate(key, 100000, 100000, "");
        donateRouter.donate(noHookKey, 100000, 100000, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feesExpected0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feesExpected1);
    }

    function test_donateToPool_RemoveNextBlock() public {
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        donateRouter.donate(key, 100000, 100000, "");
        donateRouter.donate(noHookKey, 100000, 100000, "");

        vm.roll(block.number + 1);
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function testFuzz_BlockNumberOffset_JIT(uint24 offset, uint24 removeBlockQuantity) public {
        vm.assume(offset > 1);
        vm.assume(removeBlockQuantity < offset);

        LiquidityPenaltyHook newHook = LiquidityPenaltyHook(
            address(
                uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                ) + 2 ** 96
            ) // 2**96 is an offset to avoid collision with the hook address already in the test
        );

        deployCodeTo(
            "src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, offset), address(newHook)
        );

        (PoolKey memory poolKey,) = initPool(currency0, currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);

        // add liquidity
        modifyPoolLiquidity(poolKey, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        int128 feeDonation0 =
            SafeCast.toInt128(FullMath.mulDiv(SafeCast.toUint128(feesExpected0), offset - removeBlockQuantity, offset));
        int128 feeDonation1 =
            SafeCast.toInt128(FullMath.mulDiv(SafeCast.toUint128(feesExpected1), offset - removeBlockQuantity, offset));

        // remove liquidity
        vm.roll(block.number + removeBlockQuantity);
        BalanceDelta deltaHook = modifyPoolLiquidity(poolKey, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feeDonation0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feeDonation1);
    }

    function testFuzz_BlockNumberOffset_RemoveAfterSwap(uint24 offset, uint24 removeBlockQuantity) public {
        vm.assume(offset > 1);
        vm.assume(removeBlockQuantity > offset);

        LiquidityPenaltyHook newHook = LiquidityPenaltyHook(
            address(
                uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                ) + 2 ** 96
            ) // 2**96 is an offset to avoid collision with the hook address already in the test
        );

        deployCodeTo(
            "src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, offset), address(newHook)
        );

        (PoolKey memory poolKey,) = initPool(currency0, currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);

        // add liquidity
        modifyPoolLiquidity(poolKey, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        vm.roll(block.number + removeBlockQuantity);
        BalanceDelta deltaHook = modifyPoolLiquidity(poolKey, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function test_addLiquidity_Swap_MultipleKeys_JIT() public {
        (PoolKey memory poolKeyWithHook1,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_2);
        (PoolKey memory poolKeyWithHook2,) = initPool(currency0, currency1, IHooks(address(hook)), 5000, SQRT_PRICE_2_1);

        (PoolKey memory poolKeyWithoutHook1,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_2);
        (PoolKey memory poolKeyWithoutHook2,) = initPool(currency0, currency1, IHooks(address(0)), 5000, SQRT_PRICE_2_1);

        //add liquidity to both pools
        modifyPoolLiquidity(poolKeyWithHook1, -600, 600, 1e18, 0);
        modifyPoolLiquidity(poolKeyWithHook2, -600, 600, 1e18, 0);

        modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, 1e18, 0);
        modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, 1e18, 0);

        //swap in both pools
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKeyWithHook1, swapParams, testSettings, "");
        swapRouter.swap(poolKeyWithHook2, swapParams, testSettings, "");

        swapRouter.swap(poolKeyWithoutHook1, swapParams, testSettings, "");
        swapRouter.swap(poolKeyWithoutHook2, swapParams, testSettings, "");

        (int128 feesExpected0Key1, int128 feesExpected1Key1) =
            calculateFees(manager, poolKeyWithoutHook1.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        (int128 feesExpected0Key2, int128 feesExpected1Key2) =
            calculateFees(manager, poolKeyWithoutHook2.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        //remove liquidity from both pools
        BalanceDelta deltaHook1 = modifyPoolLiquidity(poolKeyWithHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaHook2 = modifyPoolLiquidity(poolKeyWithHook2, -600, 600, -1e17, 0);

        BalanceDelta deltaNoHook1 = modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook2 = modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook1), BalanceDeltaLibrary.amount0(deltaNoHook1) - feesExpected0Key1);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook1), BalanceDeltaLibrary.amount1(deltaNoHook1) - feesExpected1Key1);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook2), BalanceDeltaLibrary.amount0(deltaNoHook2) - feesExpected0Key2);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook2), BalanceDeltaLibrary.amount1(deltaNoHook2) - feesExpected1Key2);
    }

    function test_addLiquidityMultiple_Swap_MultipleKeys_JIT() public {
        (PoolKey memory poolKeyWithHook1,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_2);
        (PoolKey memory poolKeyWithHook2,) = initPool(currency0, currency1, IHooks(address(hook)), 5000, SQRT_PRICE_2_1);

        (PoolKey memory poolKeyWithoutHook1,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_2);
        (PoolKey memory poolKeyWithoutHook2,) = initPool(currency0, currency1, IHooks(address(0)), 5000, SQRT_PRICE_2_1);

        //add liquidity to both pools
        modifyPoolLiquidity(poolKeyWithHook1, -600, 600, 1e18, 0);
        modifyPoolLiquidity(poolKeyWithHook2, -600, 600, 1e18, 0);

        modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, 1e18, 0);
        modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, 1e18, 0);

        //swap in both pools
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKeyWithHook1, swapParams, testSettings, "");
        swapRouter.swap(poolKeyWithHook2, swapParams, testSettings, "");

        swapRouter.swap(poolKeyWithoutHook1, swapParams, testSettings, "");
        swapRouter.swap(poolKeyWithoutHook2, swapParams, testSettings, "");

        (int128 feesExpected0Key1, int128 feesExpected1Key1) =
            calculateFees(manager, poolKeyWithoutHook1.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        (int128 feesExpected0Key2, int128 feesExpected1Key2) =
            calculateFees(manager, poolKeyWithoutHook2.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        //remove liquidity from pool 1 with the hook, fees should be penalized
        BalanceDelta deltaHook1 = modifyPoolLiquidity(poolKeyWithHook1, -600, 600, -1e17, 0);
        // add liquidity to pool 2 with the hook, fees should not be penalized
        BalanceDelta deltaHook2 = modifyPoolLiquidity(poolKeyWithHook2, -600, 600, 1e17, 0);

        BalanceDelta deltaNoHook1 = modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook2 = modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, 1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook1), BalanceDeltaLibrary.amount0(deltaNoHook1) - feesExpected0Key1);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook1), BalanceDeltaLibrary.amount1(deltaNoHook1) - feesExpected1Key1);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook2), BalanceDeltaLibrary.amount0(deltaNoHook2) - feesExpected0Key2);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook2), BalanceDeltaLibrary.amount1(deltaNoHook2) - feesExpected1Key2);

        vm.roll(block.number + 1);
        BalanceDelta deltaHook1NextBlock = modifyPoolLiquidity(poolKeyWithHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaHook2NextBlock = modifyPoolLiquidity(poolKeyWithHook2, -600, 600, 0, 0);

        BalanceDelta deltaHook1NoHookNextBlock = modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, -1e17, 0);
        assertEq(
            BalanceDeltaLibrary.amount0(deltaHook1NextBlock),
            BalanceDeltaLibrary.amount0(deltaHook1NoHookNextBlock) + feesExpected0Key1
        );
        assertEq(
            BalanceDeltaLibrary.amount1(deltaHook1NextBlock),
            BalanceDeltaLibrary.amount1(deltaHook1NoHookNextBlock) + feesExpected1Key1
        );

        assertEq(BalanceDeltaLibrary.amount0(deltaHook2NextBlock), feesExpected0Key2);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook2NextBlock), feesExpected1Key2);
    }
}
