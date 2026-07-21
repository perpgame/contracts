// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V4PoolKey} from "../libraries/V4PoolKey.sol";

/// @title IEquityRegistry
/// @notice Read surface of {EquityRegistry} consumed by the equity treasury and
/// its valuation library. Mirrors {IStockTokenRegistry} but:
///   - valuation is CHAINLINK (8-dec feeds, staleness-guarded), NOT Uniswap TWAP;
///   - routing exposes a v4 PoolKey (direct USDG↔token, hooks=0) instead of a
///     packed v3 path, because execution is Uniswap v4 via the forked router.
interface IEquityRegistry {
    /// @notice Allowlist gate for treasury registration.
    function tokenExists(address token) external view returns (bool);

    /// @notice Chainlink stable (6-dec) value of `amount` of `token`. Reverts on
    /// a stale/non-positive feed.
    function valueOf(address token, uint256 amount) external view returns (uint256);

    /// @notice Token amount worth `stableValue` at the Chainlink mark.
    function amountOf(address token, uint256 stableValue) external view returns (uint256);

    /// @notice Per-leg dust floor (stable base units).
    function minTradeStable() external view returns (uint256);

    /// @notice Non-reverting freshness probe: sequencer up (past grace) AND a
    /// positive answer within the feed's own `heartbeat + staleSlackSeconds`.
    /// Fresh → mint enabled + Chainlink-sized floors; not fresh → mint paused +
    /// spot-sized floors. See EQUITY_EXECUTION_PRICING_SPEC.md / hardening spec.
    function isFeedFresh(address token) external view returns (bool);

    /// @notice Reverts `SequencerDown` / `SequencerGracePeriod` when the L2
    /// sequencer is unusable; no-op when opted out. Called on the mint/NAV path
    /// so an outage surfaces DISTINCTLY from a weekend `MarketClosed`.
    function requireSequencerUp() external view;

    /// @notice Non-reverting L2 sequencer health (true = up & past grace, or
    /// guard opted out).
    function isSequencerUp() external view returns (bool);

    /// @notice MANIPULABLE spot value (6-dec) from the v4 pool's sqrtPrice —
    /// floor/divergence sizing ONLY, never a payout or NAV price.
    function spotValueOf(address token, uint256 amount) external view returns (uint256);

    /// @notice Pre-trade divergence-guard predicate (true = within band /
    /// disabled / stale).
    function divergenceOk(address token) external view returns (bool);

    /// @notice Realized-output slippage buffer (bps) when Chainlink is fresh.
    function slipBufferBps() external view returns (uint16);

    /// @notice Wider slippage buffer (bps) when Chainlink is stale (spot-sized).
    function slipBufferStaleBps() external view returns (uint16);

    /// @notice Spot-vs-Chainlink divergence band (bps); 0 = disabled.
    function maxDivergenceBps() external view returns (uint16);

    /// @notice The sorted v4 PoolKey for the direct STABLE↔token pool.
    function poolKey(address token) external view returns (V4PoolKey.PoolKey memory);

    /// @notice The v4 PoolId (keccak256(abi.encode(poolKey))).
    function poolId(address token) external view returns (bytes32);

    /// @notice True when STABLE is currency0 of the token's pool (i.e. a BUY,
    /// stable→token, swaps zeroForOne). Lets the treasury pick swap direction
    /// without re-sorting.
    function stableIsCurrency0(address token) external view returns (bool);
}
