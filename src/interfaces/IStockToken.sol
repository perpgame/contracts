// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Minimal subset of Robinhood Chain's Stock Token that the treasury reads.
/// Stock Tokens are standard 18-decimal ERC-20s (BeaconProxy → shared `Stock`
/// implementation) with issuer-side pause controls and an ERC-8056 scaled-UI
/// multiplier. Raw balances never rebase; the Chainlink feed price already
/// includes the corporate-action multiplier, so valuation uses raw balances.
/// These extra views are consumed defensively (try/catch) so that plain
/// ERC-20s without them (e.g. WETH) can still be registered.
interface IStockToken is IERC20 {
    /// Token-level transfer pause (issuer-controlled).
    function paused() external view returns (bool);
    /// Set by the issuer during corporate actions while the feed is frozen.
    function oraclePaused() external view returns (bool);
    /// ERC-8056 scaled-UI multiplier (18 decimals).
    function uiMultiplier() external view returns (uint256);
}
