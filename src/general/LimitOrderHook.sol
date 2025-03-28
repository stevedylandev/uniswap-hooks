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
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

type Epoch is uint232;

contract LimitOrderHook is BaseHook {
    error ZeroLiquidity();

    error InRange();

    bytes internal constant ZERO_BYTES = bytes("");

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

    mapping(bytes32 => Epoch) public epochs;
    mapping(Epoch => EpochInfo) public epochInfos;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function place(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) external {
        if (liquidity == 0) revert ZeroLiquidity();

        BalanceDelta delta = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tick,
                tickUpper: tick + key.tickSpacing,
                liquidityDelta: liquidity,
                salt: 0
            }),
            ZERO_BYTES
        );


    }

    /**
     * @dev Set the hook permissions, specifically `beforeSwap` and `beforeSwapReturnDelta`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
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
