// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Read surface of StockTokenRegistry consumed by treasuries and valuation.
interface IStockTokenRegistry {
    function tokenExists(address token) external view returns (bool);
    function poolFee(address token) external view returns (uint24);
    function valueOf(address token, uint256 amount) external view returns (uint256);
    function amountOf(address token, uint256 stableValue) external view returns (uint256);
    function minTradeStable() external view returns (uint256);
    function maxPriceAge() external view returns (uint256);
}
