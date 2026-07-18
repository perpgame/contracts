// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal read surface of a Uniswap v3 pool needed for TWAP valuation on
/// Robinhood Chain. We never write to pools here — pricing is derived from the
/// cumulative-tick oracle (`observe`), never from the manipulable spot tick in
/// `slot0`.
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);

    /// Current in-range state. `tick`/`sqrtPriceX96` are SPOT and manipulable —
    /// used only for `observationIndex`/cardinality bookkeeping, never pricing.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// Cumulative-tick oracle. Returns per-`secondsAgos` cumulatives; the mean
    /// tick over a window is (delta cumulative) / window.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);

    /// Grow the oracle ring buffer so longer TWAP windows are serviceable.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}
