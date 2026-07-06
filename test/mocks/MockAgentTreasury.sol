// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Minimal AgentTreasury stand-in: a settable nav() so tests can script PnL.
contract MockAgentTreasury {
    uint256 public nav;
    constructor(uint256 nav_) { nav = nav_; }
    function setNav(uint256 n) external { nav = n; }
}
