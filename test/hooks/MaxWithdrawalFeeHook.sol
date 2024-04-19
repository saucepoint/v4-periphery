// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "../../contracts/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "@uniswap/v4-core/src/libraries/CurrencySettleTake.sol";

/// @dev A hook which takes both principal liquidity and fees on LP modification
contract MaxWithdrawalFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencySettleTake for Currency;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    mapping(PoolId => uint256 count) public beforeAddLiquidityCount;
    mapping(PoolId => uint256 count) public beforeRemoveLiquidityCount;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
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

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        if (delta.amount0() > 0) key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);
        if (delta.amount1() > 0) key.currency1.take(poolManager, address(this), uint256(int256(delta.amount1())), false);
        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }
}
