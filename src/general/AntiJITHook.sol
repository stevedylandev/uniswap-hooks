// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/general/AntiJITHook.sol)

pragma solidity ^0.8.24;

import { BaseHook } from "src/base/BaseHook.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta, add as balanceDeltaAdd} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import { Position } from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract AntiJITHook is BaseHook {
    using CurrencySettler for Currency;
    using Pool for *;
    mapping(bytes32 => uint256) public _lastAddedLiquidity;
    uint256 public blockNumberOffset;

    uint256 public constant MIN_BLOCK_NUMBER_OFFSET = 1;

    error BlockNumberOffsetTooLow();


    constructor(IPoolManager _poolManager, uint256 _blockNumberOffset) BaseHook(_poolManager) {
        if(_blockNumberOffset < MIN_BLOCK_NUMBER_OFFSET) {
            revert BlockNumberOffsetTooLow();
        }
        blockNumberOffset = _blockNumberOffset;
    }  


    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta, //fees
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getPositionLiquidity(poolManager, id, positionKey);
        if (liquidity > 0) {
            _lastAddedLiquidity[positionKey] = block.number;
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta delta1, // fees
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        uint256 lastAddedLiquidity = _lastAddedLiquidity[positionKey];

        if(block.number - lastAddedLiquidity <= blockNumberOffset) {
            // donate the fees to the pool

            int128 amount0 = delta1.amount0();
            int128 amount1 = delta1.amount1();

            BalanceDelta deltaHook = _donateFees(key, amount0, amount1);

            BalanceDelta deltaSender = toBalanceDelta(-deltaHook.amount0(), -deltaHook.amount1());
            
            return (this.afterRemoveLiquidity.selector, deltaSender);
        }


        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _donateFees(PoolKey calldata key, int128 amount0, int128 amount1) internal returns (BalanceDelta) {
        _takeFeesFromPoolManager(key, amount0, amount1);
        BalanceDelta delta = poolManager.donate(key, uint256(int256(amount0)), uint256(int256(amount1)), "");
        _settleFees(key, amount0, amount1);
        return delta;
    }

    function _takeFeesFromPoolManager(PoolKey calldata key, int128 amount0, int128 amount1) internal {
        (Currency currency0, Currency currency1) = _getCurrencies(key);

        currency0.take(poolManager, address(this), uint256(int256(amount0)), true);
        currency1.take(poolManager, address(this), uint256(int256(amount1)), true);
    }

    function _settleFees(PoolKey calldata key, int128 amount0, int128 amount1) internal {
        (Currency currency0, Currency currency1) = _getCurrencies(key);

        currency0.settle(poolManager, address(this), uint256(int256(amount0)), true);
        currency1.settle(poolManager, address(this), uint256(int256(amount1)), true);
    }

    function _getCurrencies(PoolKey calldata key) internal view returns (Currency currency0, Currency currency1) {
        currency0 = key.currency0;
        currency1 = key.currency1;
    }


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