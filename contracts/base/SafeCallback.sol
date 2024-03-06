// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ILockCallback} from "@uniswap/v4-core/src/interfaces/callback/ILockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

abstract contract SafeCallback is ImmutableState, ILockCallback {
    error NotManager();

    modifier onlyByManager() {
        if (msg.sender != address(poolManager)) revert NotManager();
        _;
    }

    /// @dev There is no way to force the onlyByManager modifier but for this callback to be safe, it MUST check that the msg.sender is the pool manager.
    function lockAcquired(address, bytes calldata data) external onlyByManager returns (bytes memory) {
        return _lockAcquired(data);
    }

    function _lockAcquired(bytes calldata data) internal virtual returns (bytes memory);
}