// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Chainlink price feed (USD feeds on Robinhood Chain are 8 decimals; equity
/// feeds are tagged us_equities_24/5 — they freeze over weekends and during
/// corporate actions, so consumers must staleness-check `updatedAt`).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
