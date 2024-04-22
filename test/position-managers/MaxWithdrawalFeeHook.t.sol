// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

import {MaxWithdrawalFeeHook} from "../hooks/MaxWithdrawalFeeHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract MaxWithdrawalFeeHookTest is Test, Deployers, GasSnapshot, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;

    NonfungiblePositionManager lpm;

    MaxWithdrawalFeeHook hook = MaxWithdrawalFeeHook(
        address(
            uint160(
                uint256(type(uint160).max) & clearAllHookPermisssionsMask | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            )
        )
    );

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // unused value for the fuzz helper functions
    uint128 constant DEAD_VALUE = 6969.6969 ether;
    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        MaxWithdrawalFeeHook impl = new MaxWithdrawalFeeHook();
        vm.etch(address(hook), address(impl).code);
        hook.setManager(IPoolManager(manager));

        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);

        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency0)).transfer(bob, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(bob, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        // define a reusable range
        range = LiquidityRange({key: key, tickLower: -300, tickUpper: 300});

        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);
    }

    function test_feePreservation() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice provides liquidity
        vm.prank(alice);
        (uint256 tokenIdAlice, BalanceDelta aliceDelta) =
            lpm.mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);

        // bob provides liquidity
        vm.prank(bob);
        (uint256 tokenIdBob, BalanceDelta bobDelta) =
            lpm.mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        // alice withdraws her position and gets fully penalized
        // alice will pay tokens to offset the hook taking bob's fees
        vm.prank(alice);
        lpm.burn(tokenIdAlice, alice, abi.encode(true), false);

        assertGt(balance0BeforeAlice, currency0.balanceOf(alice));
        assertGt(balance1BeforeAlice, currency1.balanceOf(alice));

        uint256 balance0BeforeBob = currency0.balanceOf(bob);
        uint256 balance1BeforeBob = currency1.balanceOf(bob);

        // bob can withdraw principal + fees
        vm.prank(bob);
        lpm.burn(tokenIdBob, bob, abi.encode(false), false);

        assertApproxEqAbs(
            currency0.balanceOf(bob) - balance0BeforeBob,
            uint256(int256(-bobDelta.amount0()))
                + swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
            63000000 wei
        );

        assertApproxEqAbs(
            currency1.balanceOf(bob) - balance1BeforeBob,
            uint256(int256(-bobDelta.amount1()))
                + swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
            63000000 wei
        );
    }
}
