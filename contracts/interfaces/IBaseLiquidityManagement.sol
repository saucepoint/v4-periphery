// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LiquidityRange, LiquidityRangeId} from "../types/LiquidityRange.sol";

interface IBaseLiquidityManagement is IUnlockCallback {
    function liquidityOf(address owner, LiquidityRangeId positionId) external view returns (uint256 liquidity);

    // NOTE: handles add/remove/collect
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData,
        address owner
    ) external payable returns (BalanceDelta delta, BalanceDelta feeDelta);
}
