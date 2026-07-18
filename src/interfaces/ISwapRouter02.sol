// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal subset of Uniswap v3 SwapRouter02 (0xcaf681a66d020601342297493863e78c959e5cb2
/// on Robinhood Chain). Note: unlike the original SwapRouter, SwapRouter02's
/// param structs carry no `deadline` field — callers enforce their own.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// Multi-hop exact-input swap. `path` is packed (tokenIn, fee, token, fee,
    /// …, tokenOut) — Uniswap v3 encoding. Used for routes with no direct
    /// stable↔token pool (e.g. USDG → WETH → AAPL).
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
