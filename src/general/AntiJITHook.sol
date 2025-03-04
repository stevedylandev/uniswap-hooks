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
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {console} from "forge-std/console.sol";

contract AntiJITHook is BaseHook {
    using CurrencySettler for Currency;
    using Pool for *;

    mapping(PoolId id => mapping(bytes32 poisitionKey => uint256 blockNumber)) public _lastAddedLiquidity;
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
        address sender, // this is the address of the router
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta, //fees
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {

        /// important to note that the sender is not the address of the final user/LP, it's actually the address of the router
        /// the salt is actually a bytes() of tokenId, which is tokenId of the position minted by the position manager. This way, the token id actually identify 
        /// the position minted to the actual user. It's also good because even if the user transfer the position to another address, the tokenId will still be the same
        /// and the position key will be the same.
        console.log("sender after add msg.sender", msg.sender);

        console.log("sender after add", sender);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getPositionLiquidity(poolManager, id, positionKey);
        if (liquidity > 0) {
            console.log("liquidity after add", liquidity);
            // CHANGE THAT TO USE A MAPPING OF KEYS TO POSITION KEY TO BLOCK NUMBER
            _lastAddedLiquidity[id][positionKey] = block.number;
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta feeDelta, // fees
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getPositionLiquidity(poolManager, id, positionKey);

        uint256 lastAddedLiquidity = _lastAddedLiquidity[id][positionKey];

        if(block.number - lastAddedLiquidity <= blockNumberOffset) {
            // donate the fees to the pool

            BalanceDelta deltaHook = _donateFeesToPool(key, feeDelta);

            BalanceDelta deltaSender = toBalanceDelta(-deltaHook.amount0(), -deltaHook.amount1());
            
            return (this.afterRemoveLiquidity.selector, deltaSender);
        }


        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _donateFeesToPool(PoolKey calldata key, BalanceDelta feeDelta) internal returns (BalanceDelta) {
        int128 amount0 = feeDelta.amount0();
        int128 amount1 = feeDelta.amount1();

        (Currency currency0, Currency currency1) = _getCurrencies(key);

        _takeFromPoolManager(currency0, amount0);
        _takeFromPoolManager(currency1, amount1);

        BalanceDelta delta = poolManager.donate(key, uint256(int256(amount0)), uint256(int256(amount1)), "");

        _settleOnPoolManager(currency0, amount0);
        _settleOnPoolManager(currency1, amount1);

        return delta;
    }

    function _takeFromPoolManager(Currency currency, int128 amount) internal {
        currency.take(poolManager, address(this), uint256(int256(amount)), true);
    }

    function _settleOnPoolManager(Currency currency, int128 amount) internal {
        currency.settle(poolManager, address(this), uint256(int256(amount)), true);
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