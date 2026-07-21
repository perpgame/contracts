// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPermit2 (AllowanceTransfer subset)
/// @notice Minimal surface of the canonical Permit2 contract
/// (0x000000000022D473030F116dDEE9F6B43aC78BA3) used by the equity treasury to
/// fund swaps through the forked Uniswap v4 UniversalRouter.
///
/// VERIFIED: this address is the canonical Permit2 AND is the exact `permit2`
/// value the router was constructed with — decoded from the router's on-chain
/// constructor args (RouterParameters.permit2, word 0). It has deployed code on
/// Robinhood Chain (confirmed via eth_getCode).
///
/// The router pulls the input token via {transferFrom}, which requires two
/// approvals: the treasury first grants Permit2 an ERC-20 allowance on the
/// token, then registers a Permit2 allowance for the router via {approve}.
interface IPermit2 {
    /// @notice Set the router's Permit2 allowance for `token`.
    /// @param token      ERC-20 to authorize.
    /// @param spender    the router.
    /// @param amount     max pullable (uint160).
    /// @param expiration unix seconds after which the allowance lapses (uint48).
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    /// @notice Router-invoked pull of `amount` of `token` from `from` to `to`.
    function transferFrom(address from, address to, uint160 amount, address token) external;

    /// @notice Current allowance triple for (owner, token, spender).
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
