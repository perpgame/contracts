// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// Settable Chainlink L2 Sequencer Uptime Feed. Convention: `answer` 0 = UP,
/// 1 = DOWN; `startedAt` is when the current status began (0 = uninitialized).
/// `setStatus(down, startedAt)` drives the EquityRegistry sequencer guard tests.
contract MockSequencerFeed is AggregatorV3Interface {
    int256 private _answer; // 0 up, 1 down
    uint256 private _startedAt;
    uint80 private _roundId = 1;

    constructor(int256 answer_, uint256 startedAt_) {
        _answer = answer_;
        _startedAt = startedAt_;
    }

    function setStatus(bool down, uint256 startedAt_) external {
        _answer = down ? int256(1) : int256(0);
        _startedAt = startedAt_;
        _roundId++;
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function description() external pure returns (string memory) {
        return "mock L2 sequencer uptime";
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _startedAt, _roundId);
    }
}
