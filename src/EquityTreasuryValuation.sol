// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEquityRegistry} from "./interfaces/IEquityRegistry.sol";

/// Per-symbol asset config for the equity treasury. Declared here (not in
/// {EquityTreasury}) so this library and the contract share ONE definition
/// without a circular import — identical pattern to {StockTreasuryValuation}.
/// Field order/types are the storage layout for `EquityTreasury.assets` — never
/// reorder or retype across upgrades.
struct AssetConfig {
    address token;
    uint16 targetBps;
    bool registered;
}

/// @title EquityTreasuryValuation
/// @notice Read-only valuation helpers for {EquityTreasury}, extracted to keep
/// the implementation under the EIP-170 24,576-byte limit. Deployed once and
/// DELEGATECALL-linked, so every function runs in the treasury's context.
///
/// All marks are CHAINLINK marks via {EquityRegistry.valueOf} — swap slippage
/// and pool fees are not modeled here. Structurally identical to
/// {StockTreasuryValuation}; only the registry interface differs (equity vs
/// memecoin), so NAV/quote semantics stay consistent across both asset classes.
library EquityTreasuryValuation {
    uint16 private constant BPS_DENOM = 10000;

    function heldTokenValues(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IEquityRegistry registry
    ) public view returns (uint256[] memory tokenValues, uint256 totalTokenValue) {
        uint256 n = symbols.length;
        tokenValues = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            tokenValues[i] = registry.valueOf(token, bal);
            totalTokenValue += tokenValues[i];
        }
    }

    /// @notice Sum of all equity tokens held (at Chainlink marks) + idle stable.
    function nav(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 stable,
        IEquityRegistry registry
    ) public view returns (uint256 total) {
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) total += registry.valueOf(token, bal);
        }
        total += stable.balanceOf(address(this));
    }

    /// @notice Oracle-mark estimate of a seller's stable proceeds: pro-rata idle
    /// plus each leg's slice at the Chainlink mark, minus the platform fee. The
    /// actual v4 swap output differs by pool fees + slippage; callers treat this
    /// as a quote and bound the realized amount with their own `minStableOut`.
    function quoteWithdrawStable(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 stable,
        IEquityRegistry registry,
        uint256 agentShares,
        uint256 totalShares,
        uint16 feeBps
    ) public view returns (uint256) {
        if (agentShares == 0 || totalShares == 0) return 0;

        uint256 idle = stable.balanceOf(address(this));
        (, uint256 totalTokenValue) = heldTokenValues(symbols, assets, registry);

        uint256 gross = ((idle + totalTokenValue) * agentShares) / totalShares;
        return gross - (gross * feeBps) / BPS_DENOM;
    }
}
