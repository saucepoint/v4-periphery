// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "@uniswap/v4-core/src/libraries/CurrencySettleTake.sol";

/// @dev A hook which takes both principal liquidity and fees on LP modification
contract MaxWithdrawalFeeHook is BaseTestHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencySettleTake for Currency;

    IPoolManager public manager;

    function setManager(IPoolManager _manager) external {
        manager = _manager;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        bool penalty = abi.decode(hookData, (bool));
        if (penalty) {
            key.currency0.take(manager, address(this), uint256(int256(delta.amount0())), false);
            key.currency1.take(manager, address(this), uint256(int256(delta.amount1())), false);
            return (BaseTestHooks.afterRemoveLiquidity.selector, toBalanceDelta(delta.amount0(), delta.amount1()));
        } else {
            return (BaseTestHooks.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
        }
    }
}
