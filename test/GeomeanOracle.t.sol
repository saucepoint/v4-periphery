// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GetSender} from "./shared/GetSender.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {GeomeanOracle} from "../contracts/hooks/examples/GeomeanOracle.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TokenFixture} from "@uniswap/v4-core/test/foundry-tests/utils/TokenFixture.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Oracle} from "../contracts/libraries/Oracle.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TestGeomeanOracle is Test, Deployers, TokenFixture {
    using PoolIdLibrary for PoolKey;

    int24 constant MAX_TICK_SPACING = 32767;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    GeomeanOracle geomeanOracle;
    PoolKey key;
    PoolId id;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        initializeTokens();
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        manager = new PoolManager(500000);

        uint160 flags = uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            );
        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, 0, type(GeomeanOracle).creationCode, abi.encode(manager));
        geomeanOracle = new GeomeanOracle{salt: salt}(manager);
        require(address(geomeanOracle) == hookAddress, "TestGeomeanOracle: hook address mismatch");

        vm.warp(1);
        key = PoolKey(currency0, currency1, 0, MAX_TICK_SPACING, geomeanOracle);
        id = key.toId();

        modifyPositionRouter = new PoolModifyPositionTest(manager);

        token0.approve(address(geomeanOracle), type(uint256).max);
        token1.approve(address(geomeanOracle), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function testBeforeInitializeRevertsIfFee() public {
        vm.expectRevert(GeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 1, MAX_TICK_SPACING, geomeanOracle),
            SQRT_RATIO_1_1,
            ZERO_BYTES
        );
    }

    function testBeforeInitializeRevertsIfNotMaxTickSpacing() public {
        vm.expectRevert(GeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, 60, geomeanOracle),
            SQRT_RATIO_1_1,
            ZERO_BYTES
        );
    }

    function testAfterInitializeState() public {
        manager.initialize(key, SQRT_RATIO_2_1, ZERO_BYTES);
        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);
    }

    function testAfterInitializeObservation() public {
        manager.initialize(key, SQRT_RATIO_2_1, ZERO_BYTES);
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testAfterInitializeObserve0() public {
        manager.initialize(key, SQRT_RATIO_2_1, ZERO_BYTES);
        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            geomeanOracle.observe(key, secondsAgo);
        assertEq(tickCumulatives.length, 1);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 1);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    function testBeforeModifyPositionNoObservations() public {
        manager.initialize(key, SQRT_RATIO_2_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000
            )
        );

        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testBeforeModifyPositionObservation() public {
        manager.initialize(key, SQRT_RATIO_2_1, ZERO_BYTES);
        skip(2); // advance 2 seconds
        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000
            )
        );

        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 680564733841876926926749214863536422912);
    }

    function testBeforeModifyPositionObservationAndCardinality() public {
        manager.initialize(key, SQRT_RATIO_2_1, ZERO_BYTES);
        skip(2); // advance 2 seconds
        geomeanOracle.increaseCardinalityNext(key, 2);
        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 2);

        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000
            )
        );

        // cardinality is updated
        observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 1);
        assertEq(observationState.cardinality, 2);
        assertEq(observationState.cardinalityNext, 2);

        // index 0 is untouched
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);

        // index 1 is written
        observation = geomeanOracle.getObservation(key, 1);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 680564733841876926926749214863536422912);
    }
}
