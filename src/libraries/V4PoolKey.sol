// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Uniswap v4 PoolKey + poolId helpers for the equity (real tokenized-stock)
/// treasury on Robinhood Chain.
///
/// A v4 pool is identified by a `PoolKey`; its `PoolId` is the keccak256 of the
/// ABI-encoded key. In canonical v4 the key's `currency0`/`currency1` are
/// `Currency` (a `uint256`/`address` wrapper) and `hooks` is `IHooks`, but both
/// are address-width, so `keccak256(abi.encode(...))` over plain `address`
/// fields produces the SAME 32-byte-padded encoding — the poolId matches the
/// on-chain PoolManager exactly.
///
/// Equity stock pools are DIRECT USDG↔token pools with NO hook
/// (`hooks == address(0)`) at fee tier 3000 (tickSpacing 60) or 10000
/// (tickSpacing 200). Currencies MUST be sorted ascending by address.
library V4PoolKey {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice Build a sorted PoolKey for a direct STABLE↔token equity pool.
    /// @dev hooks is fixed to address(0): stock v4 pools carry no oracle hook.
    function build(address stable, address token, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address c0, address c1) = sort(stable, token);
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: address(0)});
    }

    /// @notice keccak256(abi.encode(key)) — the v4 PoolId.
    function toId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @notice Sort two currencies ascending (v4 requires currency0 < currency1).
    function sort(address a, address b) internal pure returns (address c0, address c1) {
        (c0, c1) = a < b ? (a, b) : (b, a);
    }
}
