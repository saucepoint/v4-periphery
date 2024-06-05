// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../types/LiquidityRange.sol";
import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {CurrencySettleTake} from "../libraries/CurrencySettleTake.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

// TODO: remove
import {console2} from "forge-std/console2.sol";

abstract contract BaseLiquidityManagement is SafeCallback, IBaseLiquidityManagement {
    using LiquidityRangeIdLibrary for LiquidityRange;
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error LockFailure();

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bool claims;
        bytes hookData;
    }

    mapping(address owner => mapping(LiquidityRangeId positionId => uint256 liquidity)) public liquidityOf;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    // NOTE: handles mint/remove/collect
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData,
        address owner
    ) public payable override returns (BalanceDelta delta) {
        // if removing liquidity, check that the owner is the sender?
        if (params.liquidityDelta < 0) require(msg.sender == owner, "Cannot redeem position");

        delta = abi.decode(
            poolManager.unlock(abi.encodeCall(this.handleModifyPosition, (msg.sender, key, params, hookData, false))),
            (BalanceDelta)
        );

        params.liquidityDelta < 0
            ? liquidityOf[owner][LiquidityRange(key, params.tickLower, params.tickUpper).toId()] -=
                uint256(-params.liquidityDelta)
            : liquidityOf[owner][LiquidityRange(key, params.tickLower, params.tickUpper).toId()] +=
                uint256(params.liquidityDelta);

        // TODO: handle & test
        // uint256 ethBalance = address(this).balance;
        // if (ethBalance > 0) {
        //     CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        // }
    }

    function increaseLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData,
        bool claims,
        address owner,
        uint256 token0Owed,
        uint256 token1Owed
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encodeCall(
                    this.handleIncreaseLiquidity,
                    (
                        msg.sender,
                        key,
                        params,
                        hookData,
                        claims,
                        toBalanceDelta(int128(int256(token0Owed)), int128(int256(token1Owed)))
                    )
                )
            ),
            (BalanceDelta)
        );

        liquidityOf[owner][LiquidityRange(key, params.tickLower, params.tickUpper).toId()] +=
            uint256(params.liquidityDelta);
    }

    function collect(LiquidityRange memory range, bytes calldata hookData) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encodeCall(
                    this.handleModifyPosition,
                    (
                        address(this),
                        range.key,
                        IPoolManager.ModifyLiquidityParams({
                            tickLower: range.tickLower,
                            tickUpper: range.tickUpper,
                            liquidityDelta: 0,
                            salt: 0
                        }),
                        hookData,
                        true
                    )
                )
            ),
            (BalanceDelta)
        );
    }

    function sendToken(address recipient, Currency currency, uint256 amount) internal {
        poolManager.unlock(abi.encodeCall(this.handleRedeemClaim, (recipient, currency, amount)));
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    // TODO: selfOnly modifier
    function handleModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        bool claims
    ) external returns (BalanceDelta delta) {
        (delta,) = poolManager.modifyLiquidity(key, params, hookData);

        if (params.liquidityDelta <= 0) {
            // removing liquidity/fees so mint tokens to the router
            // the router will be responsible for sending the tokens to the desired recipient
            key.currency0.take(poolManager, address(this), uint128(delta.amount0()), true);
            key.currency1.take(poolManager, address(this), uint128(delta.amount1()), true);
        } else {
            // adding liquidity so pay tokens
            key.currency0.settle(poolManager, sender, uint128(-delta.amount0()), claims);
            key.currency1.settle(poolManager, sender, uint128(-delta.amount1()), claims);
        }
    }

    // TODO: selfOnly modifier
    function handleIncreaseLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        bool claims,
        BalanceDelta tokensOwed
    ) external returns (BalanceDelta delta) {
        (,BalanceDelta feeDelta) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: 0,
                salt: 0
            }),
            hookData
        );

        poolManager.modifyLiquidity(key, params, hookData);

        {
            BalanceDelta excessFees = feeDelta - tokensOwed;
            key.currency0.take(poolManager, address(this), uint128(excessFees.amount0()), true);
            key.currency1.take(poolManager, address(this), uint128(excessFees.amount1()), true);

            int256 amount0Delta = poolManager.currencyDelta(address(this), key.currency0);
            int256 amount1Delta = poolManager.currencyDelta(address(this), key.currency1);
            if (amount0Delta < 0) key.currency0.settle(poolManager, sender, uint256(-amount0Delta), claims);
            if (amount1Delta < 0) key.currency1.settle(poolManager, sender, uint256(-amount1Delta), claims);
            if (amount0Delta > 0) key.currency0.take(poolManager, address(this), uint256(amount0Delta), true);
            if (amount1Delta > 0) key.currency1.take(poolManager, address(this), uint256(amount1Delta), true);
            delta = toBalanceDelta(int128(amount0Delta), int128(amount1Delta));
        }
    }

    // TODO: selfOnly modifier
    function handleRedeemClaim(address recipient, Currency currency, uint256 amount) external {
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
    }
}
