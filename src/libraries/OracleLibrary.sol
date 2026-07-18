// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

/// @title Oracle library
/// @notice Provides functions to integrate with a Uniswap v3 pool's TWAP oracle.
/// @dev Ported from Uniswap v3-periphery to Solidity 0.8. `consult` returns the
/// arithmetic-mean tick over `secondsAgo`; `getQuoteAtTick` converts a mean tick
/// into a quote-token amount. TWAP is manipulation-resistant because a mean over
/// N seconds cannot be moved by a single-block price spike.
library OracleLibrary {
    /// @notice Arithmetic mean tick of `pool` over the past `secondsAgo` seconds.
    function consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
        require(secondsAgo != 0, "BP");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
        // Always round to negative infinity.
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) {
            arithmeticMeanTick--;
        }
    }

    /// @notice Amount of `quoteToken` equivalent to `baseAmount` of `baseToken`
    /// at the price implied by `tick`.
    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Avoid ratioX192 overflow by branching on the magnitude of sqrtRatioX96.
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice Seconds of oracle history available on `pool` — i.e. how far back
    /// `observe` can look before it reverts "OLD". Used to reject pools whose
    /// oracle is too fresh to yield a trustworthy TWAP, and to clamp a requested
    /// window to what the ring buffer can actually serve.
    function getOldestObservationSecondsAgo(address pool) internal view returns (uint32 secondsAgo) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = IUniswapV3Pool(pool).slot0();
        require(observationCardinality > 0, "NI");

        // The oldest observation is the one at the "next" slot when the buffer is
        // full; otherwise it's index 0. If that slot isn't initialized yet, the
        // buffer hasn't wrapped, so the oldest is index 0.
        (uint32 observationTimestamp, , , bool initialized) =
            IUniswapV3Pool(pool).observations((observationIndex + 1) % observationCardinality);
        if (!initialized) {
            (observationTimestamp, , , ) = IUniswapV3Pool(pool).observations(0);
        }

        unchecked {
            // block.timestamp is truncated to uint32 the same way the pool stores it,
            // so the subtraction is correct across the 2^32 wrap.
            secondsAgo = uint32(block.timestamp) - observationTimestamp;
        }
    }
}
