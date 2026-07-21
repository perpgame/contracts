// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStateView} from "../../src/interfaces/IStateView.sol";

/// Settable Uniswap v4 StateView stub for EquityRegistry listing checks. A pool
/// is "initialized" once `setPool` gives it a non-zero sqrtPrice. Keyed by
/// poolId so a test can pre-seed the exact id the registry computes.
contract MockStateView is IStateView {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    mapping(bytes32 => Slot0) internal _slot0;
    mapping(bytes32 => uint128) internal _liquidity;

    /// Mark a pool initialized with an arbitrary non-zero price + liquidity.
    function setPool(bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity) external {
        _slot0[poolId] = Slot0({sqrtPriceX96: sqrtPriceX96, tick: 0, protocolFee: 0, lpFee: 0});
        _liquidity[poolId] = liquidity;
    }

    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        Slot0 storage s = _slot0[poolId];
        return (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee);
    }

    function getLiquidity(bytes32 poolId) external view returns (uint128) {
        return _liquidity[poolId];
    }
}
