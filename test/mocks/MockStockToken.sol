// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Minimal mock of a Robinhood Chain stock token: a standard 18-decimal ERC-20
/// with the issuer-side views AgentTreasury probes defensively. `paused` is
/// only READ by the treasury's `_isTransferPaused` try/catch — transfers stay
/// live in the mock so a test can hand-move balances even while "paused".
contract MockStockToken is ERC20 {
    bool public paused;
    bool public oraclePaused;

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }

    /// ERC-8056 scaled-UI multiplier (identity in the mock).
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }
}
