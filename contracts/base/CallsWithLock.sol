// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {ICallsWithLock} from "../interfaces/ICallsWithLock.sol";

/// @title CallsWithLock
/// @notice Handles all the calls to the pool manager contract. Assumes the integrating contract has already acquired a lock.
abstract contract CallsWithLock is ICallsWithLock, ImmutableState {
    error NotSelf();

    modifier onlyBySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    function initializeWithLock(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        onlyBySelf
        returns (bytes memory)
    {
        return abi.encode(poolManager.initialize(key, sqrtPriceX96, hookData));
    }

    function modifyPositionWithLock(
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) external onlyBySelf returns (bytes memory) {
        return abi.encode(poolManager.modifyPosition(key, params, hookData));
    }

    function swapWithLock(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        onlyBySelf
        returns (bytes memory)
    {
        return abi.encode(poolManager.swap(key, params, hookData));
    }

    function donateWithLock(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyBySelf
        returns (bytes memory)
    {
        return abi.encode(poolManager.donate(key, amount0, amount1, hookData));
    }
}