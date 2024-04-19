// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

library PoolStateLibrary {
    // forge inspect lib/v4-core/src/PoolManager.sol:PoolManager storage --pretty
    // | Name                  | Type                                                                | Slot | Offset | Bytes | Contract                                    |
    // |-----------------------|---------------------------------------------------------------------|------|--------|-------|---------------------------------------------|
    // | pools                 | mapping(PoolId => struct Pool.State)                                | 6    | 0      | 32    | lib/v4-core/src/PoolManager.sol:PoolManager |
    uint256 public constant POOLS_SLOT = 6;

    // index of feeGrowthGlobal0X128 in Pool.State
    uint256 public constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    // index of feeGrowthGlobal1X128 in Pool.State
    uint256 public constant FEE_GROWTH_GLOBAL1_OFFSET = 2;

    // index of liquidity in Pool.State
    uint256 public constant LIQUIDITY_OFFSET = 3;

    // index of TicksInfo mapping in Pool.State
    uint256 public constant TICK_INFO_OFFSET = 4;

    // index of tickBitmap mapping in Pool.State
    uint256 public constant TICK_BITMAP_OFFSET = 5;

    // index of Position.Info mapping in Pool.State
    uint256 public constant POSITION_INFO_OFFSET = 6;

    /**
     * @notice Get Slot0 of the pool: sqrtPriceX96, tick, protocolFee, swapFee
     * @dev Corresponds to pools[poolId].slot0
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return sqrtPriceX96 The square root of the price of the pool, in Q96 precision.
     * @return tick The current tick of the pool.
     * @return protocolFee The protocol fee of the pool.
     * @return swapFee The swap fee of the pool.
     */
    function getSlot0(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint24 swapFee)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        bytes32 data = manager.extsload(stateSlot);

        //   32 bits  |24bits|16bits      |24 bits|160 bits
        // 0x00000000 000bb8 0000         ffff75  0000000000000000fe3aa841ba359daa0ea9eff7
        // ---------- | fee  |protocolfee | tick  | sqrtPriceX96
        assembly {
            // bottom 160 bits of data
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            // next 24 bits of data
            tick := and(shr(160, data), 0xFFFFFF)
            // next 16 bits of data
            protocolFee := and(shr(184, data), 0xFFFF)
            // last 24 bits of data
            swapFee := and(shr(200, data), 0xFFFFFF)
        }
    }

    /**
     * @notice Retrieves the tick information of a pool at a specific tick.
     * @dev Corresponds to pools[poolId].ticks[tick]
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve information for.
     * @return liquidityGross The total position liquidity that references this tick
     * @return liquidityNet The amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
     * @return feeGrowthOutside0X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     * @return feeGrowthOutside1X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     */
    function getTickInfo(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `mapping(int24 => TickInfo) ticks`
        bytes32 ticksMapping = bytes32(uint256(stateSlot) + TICK_INFO_OFFSET);

        // slot key of the tick key: `pools[poolId].ticks[tick]
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), ticksMapping));

        // read all 3 words of the TickInfo struct
        bytes memory data = manager.extsload(slot, 3);
        assembly {
            liquidityGross := shr(128, mload(add(data, 32)))
            liquidityNet := and(mload(add(data, 32)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            feeGrowthOutside0X128 := mload(add(data, 64))
            feeGrowthOutside1X128 := mload(add(data, 96))
        }
    }

    /**
     * @notice Retrieves the liquidity information of a pool at a specific tick.
     * @dev Corresponds to pools[poolId].ticks[tick].liquidityGross and pools[poolId].ticks[tick].liquidityNet. A more gas efficient version of getTickInfo
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve liquidity for.
     * @return liquidityGross The total position liquidity that references this tick
     * @return liquidityNet The amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
     */
    function getTickLiquidity(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `mapping(int24 => TickInfo) ticks`
        bytes32 ticksMapping = bytes32(uint256(stateSlot) + TICK_INFO_OFFSET);

        // slot key of the tick key: `pools[poolId].ticks[tick]
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), ticksMapping));

        bytes32 value = manager.extsload(slot);
        assembly {
            liquidityNet := shr(128, value)
            liquidityGross := and(value, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /**
     * @notice Retrieves the fee growth outside a tick range of a pool
     * @dev Corresponds to pools[poolId].ticks[tick].feeGrowthOutside0X128 and pools[poolId].ticks[tick].feeGrowthOutside1X128. A more gas efficient version of getTickInfo
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve fee growth for.
     * @return feeGrowthOutside0X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     * @return feeGrowthOutside1X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     */
    function getTickFeeGrowthOutside(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `mapping(int24 => TickInfo) ticks`
        bytes32 ticksMapping = bytes32(uint256(stateSlot) + TICK_INFO_OFFSET);

        // slot key of the tick key: `pools[poolId].ticks[tick]
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), ticksMapping));

        // TODO: offset to feeGrowth, to avoid 3-word read
        bytes memory data = manager.extsload(slot, 3);
        assembly {
            feeGrowthOutside0X128 := mload(add(data, 64))
            feeGrowthOutside1X128 := mload(add(data, 96))
        }
    }

    /**
     * @notice Retrieves the global fee growth of a pool.
     * @dev Corresponds to pools[poolId].feeGrowthGlobal0X128 and pools[poolId].feeGrowthGlobal1X128
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return feeGrowthGlobal0 The global fee growth for token0.
     * @return feeGrowthGlobal1 The global fee growth for token1.
     */
    function getFeeGrowthGlobal(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State, `uint256 feeGrowthGlobal0X128`
        bytes32 slot_feeGrowthGlobal0X128 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);

        // reads 3rd word of Pool.State, `uint256 feeGrowthGlobal1X128`
        // bytes32 slot_feeGrowthGlobal1X128 = bytes32(uint256(stateSlot) + uint256(FEE_GROWTH_GLOBAL1_OFFSET));

        // feeGrowthGlobal0 = uint256(manager.extsload(slot_feeGrowthGlobal0X128));
        // feeGrowthGlobal1 = uint256(manager.extsload(slot_feeGrowthGlobal1X128));

        // read the 2 words of feeGrowthGlobal
        bytes memory data = manager.extsload(slot_feeGrowthGlobal0X128, 2);
        assembly {
            feeGrowthGlobal0 := mload(add(data, 32))
            feeGrowthGlobal1 := mload(add(data, 64))
        }
    }

    /**
     * @notice Retrieves total the liquidity of a pool.
     * @dev Corresponds to pools[poolId].liquidity
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return liquidity The liquidity of the pool.
     */
    function getLiquidity(IPoolManager manager, PoolId poolId) internal view returns (uint128 liquidity) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `uint128 liquidity`
        bytes32 slot = bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET);

        liquidity = uint128(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the tick bitmap of a pool at a specific tick.
     * @dev Corresponds to pools[poolId].tickBitmap[tick]
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve the bitmap for.
     * @return tickBitmap The bitmap of the tick.
     */
    function getTickBitmap(IPoolManager manager, PoolId poolId, int16 tick)
        internal
        view
        returns (uint256 tickBitmap)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `mapping(int16 => uint256) tickBitmap;`
        bytes32 tickBitmapMapping = bytes32(uint256(stateSlot) + TICK_BITMAP_OFFSET);

        // slot id of the mapping key: `pools[poolId].tickBitmap[tick]
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), tickBitmapMapping));

        tickBitmap = uint256(manager.extsload(slot));
    }

    /**
     * @notice Retrieves the position information of a pool at a specific position ID.
     * @dev Corresponds to pools[poolId].positions[positionId]
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param positionId The ID of the position.
     * @return liquidity The liquidity of the position.
     * @return feeGrowthInside0LastX128 The fee growth inside the position for token0.
     * @return feeGrowthInside1LastX128 The fee growth inside the position for token1.
     */
    function getPositionInfo(IPoolManager manager, PoolId poolId, bytes32 positionId)
        internal
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `mapping(bytes32 => Position.Info) positions;`
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITION_INFO_OFFSET);

        // first value slot of the mapping key: `pools[poolId].positions[positionId] (liquidity)
        bytes32 slot = keccak256(abi.encodePacked(positionId, positionMapping));

        // read all 3 words of the Position.Info struct
        bytes memory data = manager.extsload(slot, 3);

        assembly {
            liquidity := mload(add(data, 32))
            feeGrowthInside0LastX128 := mload(add(data, 64))
            feeGrowthInside1LastX128 := mload(add(data, 96))
        }
    }

    /**
     * @notice Retrieves the liquidity of a position.
     * @dev Corresponds to pools[poolId].positions[positionId].liquidity. A more gas efficient version of getPositionInfo
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param positionId The ID of the position.
     * @return liquidity The liquidity of the position.
     */
    function getPositionLiquidity(IPoolManager manager, PoolId poolId, bytes32 positionId)
        internal
        view
        returns (uint128 liquidity)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(POOLS_SLOT)));

        // Pool.State: `mapping(bytes32 => Position.Info) positions;`
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITION_INFO_OFFSET);

        // first value slot of the mapping key: `pools[poolId].positions[positionId] (liquidity)
        bytes32 slot = keccak256(abi.encodePacked(positionId, positionMapping));

        liquidity = uint128(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Live calculate the fee growth inside a tick range of a pool
     * @dev pools[poolId].feeGrowthInside0LastX128 in Position.Info is cached and can become stale. This function will live calculate the feeGrowthInside
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tickLower The lower tick of the range.
     * @param tickUpper The upper tick of the range.
     * @return feeGrowthInside0X128 The fee growth inside the tick range for token0.
     * @return feeGrowthInside1X128 The fee growth inside the tick range for token1.
     */
    function getFeeGrowthInside(IPoolManager manager, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = getFeeGrowthGlobal(manager, poolId);

        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickUpper);
        (, int24 tickCurrent,,) = getSlot0(manager, poolId);
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }
}
