// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";

/// Configurable Uniswap v3 pool stub for TWAP-valuation tests.
///
/// The pool behaves as if it has traded at a CONSTANT `meanTick` for the whole
/// of `historySeconds`: `observe` returns cumulatives whose delta over any
/// window is exactly `meanTick × window`. `spotTick` is a SEPARATE knob exposed
/// only through `slot0().tick` — it models an in-transaction price shove and
/// must NOT influence anything the registry prices off (that's the whole point
/// of using the oracle, not slot0).
contract MockUniswapV3Pool is IUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint128 public liquidity;

    int24 public meanTick; // what the TWAP oracle reflects
    int24 public spotTick; // manipulable in-block spot — registry must ignore it
    uint32 public historySeconds = 3600; // oracle history available

    constructor(address tokenA, address tokenB, uint24 fee_, uint128 liquidity_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        liquidity = liquidity_;
    }

    function setMeanTick(int24 t) external {
        meanTick = t;
    }

    function setSpotTick(int24 t) external {
        spotTick = t;
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function setHistory(uint32 s) external {
        historySeconds = s;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        // observationIndex=1, cardinality=2 → oldest lives at slot 0.
        return (0, spotTick, 1, 2, 2, 0, true);
    }

    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56, uint160, bool initialized)
    {
        if (index == 0) {
            return (uint32(block.timestamp) - historySeconds, 0, 0, true);
        }
        return (0, 0, 0, false);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            uint256 t = uint256(uint32(block.timestamp)) - secondsAgos[i];
            tickCumulatives[i] = int56(meanTick) * int56(int256(t));
        }
    }

    function increaseObservationCardinalityNext(uint16) external {}
}
