// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.0.0) (src/general/AntiJITHook.sol)

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


/**
 * This hook implements a mechanism to prevent JIT (Just in Time) attacks on liquidity pools.
 * Specifically, it checks if a liquidity position was added to the pool within a certain block number range
 * (at least 1 block) and if so, it donates the fees to the pool. This way, the hook effectively tax JIT attackers by
 * donating their expected profits back to the pool.
 * 
 * At constructor, the hook requires a block number offset. This offset is the number of blocks at which the hook will 
 * donate the fees to the pool. The minimum value is 1.
 * 
 * NOTE: The hook donates the fees to the current in range liquidity providers (at the time of liquidity removal).
 * If the block number offset is much later than the actual block number when the liquidity was added, the liquiditity providers
 * benefited from the fees will be the ones in range at the time of liquidity removal, not the ones in range at the time of liquidity addition.
 * 
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 * 
 */

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
        BalanceDelta,
        BalanceDelta, //fees
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {

        /// important to note that the sender is not the address of the final user/LP, it's actually the address of the router
        /// the salt is actually a bytes() of tokenId, which is tokenId of the position minted by the position manager. This way, the token id actually identify 
        /// the position minted to the actual user. It's also good because even if the user transfer the position to another address, the tokenId will still be the same
        /// and the position key will be the same.
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getPositionLiquidity(poolManager, id, positionKey);
        if (liquidity > 0) {
            _lastAddedLiquidity[id][positionKey] = block.number;
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta, // fees
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId id = key.toId();
        uint256 lastAddedLiquidity = _lastAddedLiquidity[id][positionKey];

        if(block.number - lastAddedLiquidity < blockNumberOffset) {
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

    function _getCurrencies(PoolKey calldata key) internal pure returns (Currency currency0, Currency currency1) {
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