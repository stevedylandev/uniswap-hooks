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
import {LimitOrderHook, Epoch, EpochLibrary} from "src/general/LimitOrderHook.sol";

contract TestLimitOrder is Test, Deployers {
    LimitOrderHook hook;

    using StateLibrary for IPoolManager;

    //uint160 constant SQRT_PRICE_10_1 = 250541448375047931186413801569;

    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHook(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

        deployCodeTo("src/general/LimitOrderHook.sol:LimitOrderHook", abi.encode(manager), address(hook));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_getTickLowerLast() public {
        assertEq(hook.getTickLowerLast(id), 0);
    }

    function test_epochNext() public {
        assertTrue(EpochLibrary.equals(hook.epochNext(), Epoch.wrap(1)));
    }

    function test_zeroLiquidityRevert() public {
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.place(key, 0, true, 0);
    }

    function test_zeroForOneRightBoundaryOfCurrentRange() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.place(key, tickLower, zeroForOne, liquidity);

        assertTrue(EpochLibrary.equals(hook.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_zeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.place(key, tickLower, zeroForOne, liquidity);

        assertTrue(EpochLibrary.equals(hook.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_zeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.place(key, -60, true, 1000000);
    }

    function test_zeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.place(key, 0, true, 1000000);
    }

    function test_notZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = -60;
        bool zeroForOne = false;
        uint128 liquidity = 1000000;

        hook.place(key, tickLower, zeroForOne, liquidity);

        assertTrue(EpochLibrary.equals(hook.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_notZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.place(key, 0, false, 1000000);
    }

    function test_notZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.place(key, -60, false, 1000000);
    }

    function test_multipleLPs() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.place(key, tickLower, zeroForOne, liquidity);

        currency0.transfer(vm.addr(1), 1e18);
        currency1.transfer(vm.addr(2), 1e18);

        vm.startPrank(vm.addr(1));
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 1e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 1e18);
        hook.place(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();

        assertTrue(EpochLibrary.equals(hook.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity * 2);

        (
            bool filled,
            Currency epochCurrency0,
            Currency epochCurrency1,
            uint256 currency0Total,
            uint256 currency1Total,
            uint128 liquidityTotal
        ) = hook.epochInfos(Epoch.wrap(1));
        assertFalse(filled);
        assertTrue(currency0 == epochCurrency0);
        assertTrue(currency1 == epochCurrency1);
        assertEq(currency0Total, 0);
        assertEq(currency1Total, 0);
        assertEq(liquidityTotal, liquidity * 2);
        assertEq(hook.getEpochLiquidity(Epoch.wrap(1), address(this)), liquidity);
        assertEq(hook.getEpochLiquidity(Epoch.wrap(1), vm.addr(1)), liquidity);
    }

    function test_kill() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.place(key, tickLower, zeroForOne, liquidity);

        hook.kill(key, tickLower, zeroForOne, address(this));
    }
}
