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
    bytes32 bobSalt = keccak256(abi.encode(bob));

    address attacker = makeAddr("attacker"); // JIT attacker
    bytes32 attackerSalt = keccak256(abi.encode(attacker));

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

        assertEq(deltaHook, deltaNoHook, "no swaps => equivalent behavior");
    }

    function test_JIT_Swap() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, bobSalt);
        modifyPoolLiquidity(key, -600, 600, 1e18, attackerSalt);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, bobSalt);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, attackerSalt);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // calculate lp fees earned due to the swap
        BalanceDelta hookFeeDeltaBob =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        assertEitherGt(hookFeeDeltaBob, toBalanceDelta(0, 0), "Bob earned fees");

        BalanceDelta hookFeeDeltaAttacker =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, attackerSalt);
        assertEitherGt(hookFeeDeltaAttacker, toBalanceDelta(0, 0), "Attacker earned fees");

        BalanceDelta noHookFeeDeltaBob =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        assertEitherGt(noHookFeeDeltaBob, toBalanceDelta(0, 0), "Bob earned fees");

        BalanceDelta noHookFeeDeltaAttacker =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, attackerSalt);
        assertEitherGt(noHookFeeDeltaAttacker, toBalanceDelta(0, 0), "Attacker earned fees");

        assertEq(hookFeeDeltaBob, noHookFeeDeltaBob, "feeDelta equal between pools");
        assertEq(hookFeeDeltaAttacker, noHookFeeDeltaAttacker, "feeDelta equal between pools");

        // attacker removes the entire liquidity in the same block (consolidates JIT attack), penalty is applied.
        vm.expectEmit(false, false, true, true);
        emit Donate(
            key.toId(), address(0), uint128(hookFeeDeltaAttacker.amount0()), uint128(hookFeeDeltaAttacker.amount1())
        );
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e18, attackerSalt);

        // attacker removes liquidity in the unhooked pool without penalty
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e18, attackerSalt);

        assertEq(deltaHook, deltaNoHook - hookFeeDeltaAttacker, "JIT penalty applied in hooked pool");

        // attacker's feeDelta is zero
        BalanceDelta hookFeeDeltaAttackerAfterRemoval =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, attackerSalt);
        assertEq(hookFeeDeltaAttackerAfterRemoval, toBalanceDelta(0, 0), "Attacker's feeDelta zero");

        // bob should have received the attacker's fees donation in the hooked pool
        BalanceDelta hookFeeDeltaBobAfterRemoval =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        assertEq(hookFeeDeltaBobAfterRemoval, hookFeeDeltaBob + hookFeeDeltaAttacker, "Bob received attacker's fees");
    }

    function test_JIT_addLiquidityFeeCollection() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, bobSalt);
        modifyPoolLiquidity(key, -600, 600, 1e18, attackerSalt);

        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, bobSalt);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, attackerSalt);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // calculate lp fees before adding liquidity
        BalanceDelta hookFeeDeltaBefore =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        BalanceDelta noHookFeeDeltaBefore =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        assertEq(hookFeeDeltaBefore, noHookFeeDeltaBefore, "fees should be equivalent on both pools");

        // add a very small amount of liquidity (1e14 wei), which triggers fee collection
        BalanceDelta deltaHookBob = modifyPoolLiquidity(key, -600, 600, 1e14, bobSalt);
        BalanceDelta deltaHookAttacker = modifyPoolLiquidity(key, -600, 600, 1e14, attackerSalt);

        BalanceDelta deltaNoHookBob = modifyPoolLiquidity(noHookKey, -600, 600, 1e14, bobSalt);
        BalanceDelta deltaNoHookAttacker = modifyPoolLiquidity(noHookKey, -600, 600, 1e14, attackerSalt);

        // calculate lp fees after adding liquidity
        BalanceDelta hookFeeDeltaAfter =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        BalanceDelta noHookFeeDeltaAfter =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);

        // on the unhooked pool, both the attacker and bob should have collected their fees
        assertEq(noHookFeeDeltaAfter, toBalanceDelta(0, 0), "feesAccrued reduced to zero");
        // on the hooked pool, both the attacker and bob should have their fees withold by the hook
        assertEq(hookFeeDeltaAfter, toBalanceDelta(0, 0), "feesAccrued reduced to zero");

        // assert collection on unhooked and witheld on hooked
        assertEq(
            deltaHookBob, deltaNoHookBob - noHookFeeDeltaBefore, "bob collected on unhooked, but witheld in hook"
        );
        assertEq(
            deltaHookAttacker,
            deltaNoHookAttacker - noHookFeeDeltaBefore,
            "attacker collected on unhooked, but witheld in hooked"
        );

        // hook should hold ERC-6909 claims for both bob and attacker's fees
        uint256 hookClaims0 = manager.balanceOf(address(key.hooks), currency0.toId());
        uint256 hookClaims1 = manager.balanceOf(address(key.hooks), currency1.toId());

        assertEq(hookClaims0, uint256(uint128(hookFeeDeltaBefore.amount0() + hookFeeDeltaBefore.amount0())), "hook claims balance 0");
        assertEq(hookClaims1, uint256(uint128(hookFeeDeltaBefore.amount1() + hookFeeDeltaBefore.amount1())), "hook claims balance 1");

        // now, the attacker removes liquidity to consolidate JIT attack
        // BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e18, attackerSalt);
        // BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e18, attackerSalt);

        // vm.roll(block.number + 1);
    }

    function test_JIT_SingleLP() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // calculate earned fees due to the swap
        BalanceDelta hookFeeDelta =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        BalanceDelta noHookFeeDelta =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        assertEq(hookFeeDelta, noHookFeeDelta, "feeDelta equal between pools");

        // remove liquidity during the same block (consolidate JIT attack), apply penalty
        vm.expectEmit(false, false, true, true);
        emit Donate(key.toId(), address(0), uint128(hookFeeDelta.amount0()), uint128(hookFeeDelta.amount1()));
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);
        assertEq(deltaHook, deltaNoHook - hookFeeDelta, "JIT penalty applied in hooked pool");

        // since the ataccker is the only LP, he should have been the recipient of the donation
        BalanceDelta hookFeeDeltaAfterRemoval =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        assertAproxEqAbs(hookFeeDeltaAfterRemoval, hookFeeDelta, 1, "Attacker received donation");

        // unhooked pool should have collected the fees already during liquidity removal
        BalanceDelta noHookFeeDeltaAfterRemoval =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));
        assertEq(noHookFeeDeltaAfterRemoval, toBalanceDelta(0, 0), "Unhooked pool collected fees");
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

        assertEq(deltaHook, deltaNoHook, "Penalty not applied when removing entire liquidity");
    }

    function test_JIT_MultipleSwaps() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, bobSalt);
        modifyPoolLiquidity(key, -600, 600, 1e18, attackerSalt);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, bobSalt);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, attackerSalt);

        // swap with all possible combinations of zeroForOne and amountSpecified
        swapAllCombinations(key, 1e15);
        swapAllCombinations(noHookKey, 1e15);

        BalanceDelta hookFeesBob =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        BalanceDelta hookFeesAttacker =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, attackerSalt);

        BalanceDelta noHookFeesBob =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        BalanceDelta noHookFeesAttacker =
            calculateFeeDelta(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, attackerSalt);

        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e18, attackerSalt);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e18, attackerSalt);

        // attacker's feeDelta is zero
        BalanceDelta hookFeesAttackerAfterRemoval =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, attackerSalt);
        assertEq(hookFeesAttackerAfterRemoval, toBalanceDelta(0, 0), "Attacker's feeDelta zero");

        // bob received attacker's fees
        BalanceDelta hookFeesBobAfterRemoval =
            calculateFeeDelta(manager, key.toId(), address(modifyLiquidityRouter), -600, 600, bobSalt);
        assertEq(hookFeesBobAfterRemoval, hookFeesBob + hookFeesAttacker, "Bob received attacker's fees");
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

    function test_JIT_MultipleKeys() public {
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

        // calculate fees
        BalanceDelta noHookFeesKey1 = calculateFeeDelta(
            manager, poolKeyWithoutHook1.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0)
        );
        BalanceDelta noHookFeesKey2 = calculateFeeDelta(
            manager, poolKeyWithoutHook2.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0)
        );

        // remove liquidity from both pools
        BalanceDelta deltaHook1 = modifyPoolLiquidity(poolKeyWithHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaHook2 = modifyPoolLiquidity(poolKeyWithHook2, -600, 600, -1e17, 0);

        BalanceDelta deltaNoHook1 = modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook2 = modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, -1e17, 0);

        assertEq(deltaHook1, deltaNoHook1 - noHookFeesKey1);
        assertEq(deltaHook2, deltaNoHook2 - noHookFeesKey2);
    }
}
