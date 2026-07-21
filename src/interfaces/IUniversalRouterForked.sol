// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IUniversalRouterForked
/// @notice Execution surface of the MODIFIED UniversalRouter fork deployed on
/// Robinhood Chain at 0x8876789976dEcBfCbBbe364623C63652db8C0904.
///
/// The top-level `execute(commands, inputs, deadline)` entrypoint matches the
/// canonical Uniswap UniversalRouter. The DIVERGENCE is inside the V4_SWAP
/// command's per-action parameter encoding: the fork's exact-in single-swap
/// struct carries an EXTRA `minHopPriceX36` field not present in the upstream
/// `IV4Router.ExactInputSingleParams`. Standard Uniswap v4 SDK / periphery
/// calldata therefore does NOT decode correctly against this router — the swap
/// params must be hand-encoded (see {V4SwapEncoder}).
///
/// OPEN QUESTION (blocking): the byte offset / ordering / semantics of
/// `minHopPriceX36` within the action params is UNVERIFIED. It must be
/// confirmed against the router's source or verified ABI before execution can
/// be trusted. See docs/EQUITY_TREASURY_SPEC.md → "Open questions & risks".
interface IUniversalRouterForked {
    /// @param commands One byte per command (e.g. 0x10 = V4_SWAP).
    /// @param inputs   ABI-encoded input blob per command, index-aligned to `commands`.
    /// @param deadline Unix seconds after which the whole batch reverts.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
