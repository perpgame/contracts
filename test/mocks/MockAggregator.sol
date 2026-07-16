// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// Settable Chainlink feed. `setAnswer` refreshes `updatedAt` to now (like a
/// real round); `setUpdatedAt` back-dates it to exercise staleness checks.
contract MockAggregator is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId = 1;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "mock feed";
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
