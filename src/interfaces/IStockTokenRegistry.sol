// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Read surface of StockTokenRegistry consumed by treasuries and valuation.
interface IStockTokenRegistry {
    function tokenExists(address token) external view returns (bool);
    function poolFee(address token) external view returns (uint24);
    /// Packed Uniswap v3 swap paths (multi-hop where there's no direct pool).
    function buyPath(address token) external view returns (bytes memory);
    function sellPath(address token) external view returns (bytes memory);
    function valueOf(address token, uint256 amount) external view returns (uint256);
    function amountOf(address token, uint256 stableValue) external view returns (uint256);
    function minTradeStable() external view returns (uint256);
    /// TWAP window (seconds) NAV is priced over.
    function twapWindow() external view returns (uint32);
}
