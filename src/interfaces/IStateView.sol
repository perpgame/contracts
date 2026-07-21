// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStateView
/// @notice Minimal read surface of the Uniswap v4 StateView lens on Robinhood
/// Chain (0xF3334192D15450CdD385c8B70e03f9A6bD9E673b). Used only to confirm a
/// pool is initialized (non-zero sqrtPrice) and to read live liquidity when
/// gating a listing. NEVER used for pricing — equity valuation is Chainlink
/// (stock v4 pools have no oracle hook, so on-chain TWAP is impossible).
interface IStateView {
    /// @notice Current pool state. A non-zero `sqrtPriceX96` means initialized.
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice Total in-range liquidity of the pool.
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}
