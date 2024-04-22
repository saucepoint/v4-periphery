// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "@uniswap/v4-core/src/libraries/CurrencySettleTake.sol";
import {LiquidityRange, LiquidityRangeIdLibrary} from "./types/LiquidityRange.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {PoolStateLibrary} from "./libraries/PoolStateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

// TODO: remove
import {console2} from "forge-std/console2.sol";

contract NonfungiblePositionManager is BaseLiquidityManagement, INonfungiblePositionManager, ERC721 {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolStateLibrary for IPoolManager;
    /// @dev The ID of the next token that will be minted. Skips 0

    uint256 private _nextId = 1;
    mapping(uint256 tokenId => Position position) public positions;

    constructor(IPoolManager _poolManager) BaseLiquidityManagement(_poolManager) ERC721("Uniswap V4 LP", "LPT") {}

    // --- View Functions --- //
    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed) {
        Position memory position = positions[tokenId];

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = poolManager.getFeeGrowthInside(
            position.range.key.toId(), position.range.tickLower, position.range.tickUpper
        );

        (token0Owed, token1Owed) = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );
        token0Owed += position.tokensOwed0;
        token1Owed += position.tokensOwed1;
    }

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    // TODO: deadline check
    function mint(
        LiquidityRange calldata range,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes calldata hookData
    ) public payable returns (uint256 tokenId, BalanceDelta delta) {
        (delta,) = BaseLiquidityManagement.modifyLiquidity(
            range.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: range.tickLower,
                tickUpper: range.tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            hookData,
            recipient
        );

        // mint receipt token
        // GAS: uncheck this mf
        _mint(recipient, (tokenId = _nextId++));

        positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            range: range,
            liquidity: uint128(liquidity),
            feeGrowthInside0LastX128: 0, // TODO:
            feeGrowthInside1LastX128: 0, // TODO:
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        // TODO: event
    }

    // NOTE: more expensive since LiquidityAmounts is used onchain
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, BalanceDelta delta) {
        (uint160 sqrtPriceX96,,,) = PoolStateLibrary.getSlot0(poolManager, params.range.key.toId());
        uint256 liqDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(params.range.tickLower),
            TickMath.getSqrtRatioAtTick(params.range.tickUpper),
            params.amount0Desired,
            params.amount1Desired
        );
        (tokenId, delta) = mint(params.range, liqDelta, params.deadline, params.recipient, params.hookData);
        require(params.amount0Min <= uint256(uint128(delta.amount0())), "INSUFFICIENT_AMOUNT0");
        require(params.amount1Min <= uint256(uint128(delta.amount1())), "INSUFFICIENT_AMOUNT1");
    }

    function increaseLiquidity(IncreaseLiquidityParams memory params, bytes calldata hookData, bool claims)
        public
        isAuthorizedForToken(params.tokenId)
        returns (BalanceDelta delta)
    {
        require(params.liquidityDelta != 0, "Must increase liquidity");
        Position storage position = positions[params.tokenId];

        BalanceDelta tokensOwed = _updateFeeGrowth(position);

        delta = BaseLiquidityManagement.increaseLiquidity(
            position.range.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.range.tickLower,
                tickUpper: position.range.tickUpper,
                liquidityDelta: int256(uint256(params.liquidityDelta))
            }),
            hookData,
            claims,
            ownerOf(params.tokenId),
            uint128(tokensOwed.amount0()),
            uint128(tokensOwed.amount1())
        );
        // TODO: slippage checks & test

        delta.amount0() > 0 ? position.tokensOwed0 += uint128(delta.amount0()) : position.tokensOwed0 = 0;
        delta.amount1() > 0 ? position.tokensOwed1 += uint128(delta.amount1()) : position.tokensOwed1 = 0;
        position.liquidity += params.liquidityDelta;
    }

    function decreaseLiquidity(DecreaseLiquidityParams memory params, bytes calldata hookData)
        public
        isAuthorizedForToken(params.tokenId)
        returns (BalanceDelta delta)
    {
        require(params.liquidityDelta != 0, "Must decrease liquidity");
        LiquidityRange memory range = positions[params.tokenId].range;
        poolManager.unlock(
            abi.encodeCall(
                this.handleDecreaseLiquidity,
                (
                    msg.sender,
                    range.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: range.tickLower,
                        tickUpper: range.tickUpper,
                        liquidityDelta: -int256(uint256(params.liquidityDelta))
                    }),
                    hookData,
                    params.tokenId
                )
            )
        );
    }

    function burn(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta)
    {
        // remove liquidity
        Position storage position = positions[tokenId];
        if (0 < position.liquidity) {
            decreaseLiquidity(
                DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidityDelta: position.liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: recipient,
                    deadline: block.timestamp
                }),
                hookData
            );
        }

        require(position.tokensOwed0 == 0 && position.tokensOwed1 == 0, "NOT_EMPTY");
        delete positions[tokenId];

        // burn the token
        _burn(tokenId);
    }

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        returns (BalanceDelta delta)
    {
        Position storage position = positions[tokenId];
        BaseLiquidityManagement.collect(position.range, hookData);

        delta = _updateFeeGrowth(position);

        // TODO: for now we'll assume user always collects the totality of their fees
        if (claims) {
            poolManager.transfer(recipient, position.range.key.currency0.toId(), uint128(delta.amount0()) + position.tokensOwed0);
            poolManager.transfer(recipient, position.range.key.currency1.toId(), uint128(delta.amount1()) + position.tokensOwed1);
        } else {
            sendToken(recipient, position.range.key.currency0, uint128(delta.amount0()) + position.tokensOwed0);
            sendToken(recipient, position.range.key.currency1, uint128(delta.amount1()) + position.tokensOwed1);
        }

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        // TODO: event
    }

    function _updateFeeGrowth(Position storage position) internal returns (BalanceDelta tokensOwed) {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = poolManager.getFeeGrowthInside(
            position.range.key.toId(), position.range.tickLower, position.range.tickUpper
        );

        (uint128 token0Owed, uint128 token1Owed) = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );
        tokensOwed = toBalanceDelta(int128(token0Owed), int128(token1Owed));

        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal override {
        Position storage position = positions[firstTokenId];
        position.operator = address(0x0);
        liquidityOf[from][position.range.toId()] -= position.liquidity;
        liquidityOf[to][position.range.toId()] += position.liquidity;
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }

    // TODO: reorganize this better
    function handleDecreaseLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        uint256 tokenId
    ) external {
        // callerDelta: the delta after the hook has taken deltas; principal + feesAccrued - hookDelta
        // feesAccrued: the fees accrued by PositionManager (for the given range)
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        Position storage position = positions[tokenId];

        console2.log(sender);

        // new fees owed to the user's since the last update
        BalanceDelta tokensOwed = _updateFeeGrowth(position);

        // claim external fees owed to the PositionManager
        if (feesAccrued.amount0() > tokensOwed.amount0()) key.currency0.take(poolManager, address(this), uint256(int256(feesAccrued.amount0() - tokensOwed.amount0())), false);
        if (feesAccrued.amount1() > tokensOwed.amount1()) key.currency1.take(poolManager, address(this), uint256(int256(feesAccrued.amount1() - tokensOwed.amount1())), false);

        // pay out remaining principal + fees to the user
        console2.log("A");
        {
            if (callerDelta.amount0() > feesAccrued.amount0()) {
                // (feesAccrued - tokensOwed) = external fees that should not be paid out
                key.currency0.take(
                    poolManager,
                    sender,
                    uint256(int256(callerDelta.amount0() - (feesAccrued.amount0()))),
                    false
                );
            }
            if (callerDelta.amount0() > feesAccrued.amount1()) {
                key.currency1.take(
                    poolManager,
                    sender,
                    uint256(int256(callerDelta.amount1() - (feesAccrued.amount1()))),
                    false
                );
            }
        }

        // settle any deltas
        console2.log("B");
        {
            int256 currency0Delta = poolManager.currencyDelta(address(this), key.currency0);
            console2.log(currency0Delta);
            int256 currency1Delta = poolManager.currencyDelta(address(this), key.currency1);
            if (currency0Delta < 0) key.currency0.settle(poolManager, sender, uint256(-currency0Delta), false);
            if (currency1Delta < 0) key.currency1.settle(poolManager, sender, uint256(-currency1Delta), false);
        }


        // notes: alice is being charged correctly
        // alice is claiming bob's fees to the position manager
        // TODO: figure out how to send bob's fees from the position manager, without sending alice's fees
        // pay out unclaimed fees to the user
        {
            if (position.tokensOwed0 > 0) {
                console2.log(position.tokensOwed0);
                console2.log(key.currency0.balanceOf(address(this)));
                IERC20(Currency.unwrap(key.currency0)).transfer(sender, position.tokensOwed0 + uint128(tokensOwed.amount0()));
                position.tokensOwed0 = 0;
            }
            if (position.tokensOwed1 > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(sender, position.tokensOwed1 + uint128(tokensOwed.amount1()));
                position.tokensOwed1 = 0;
            }
        }

        // TODO: fix this
        // position.liquidity -= uint128(int128(params.liquidityDelta));
        // liquidityOf[ownerOf(tokenId)][position.range.toId()] -= uint256(params.liquidityDelta);
    }
}
