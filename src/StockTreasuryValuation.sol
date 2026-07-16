// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStockTokenRegistry} from "./interfaces/IStockTokenRegistry.sol";

/// Per-symbol asset config. Declared here (not in AgentTreasury) so this
/// library and the contract share one definition without a circular import.
/// Field order/types are the storage layout for `AgentTreasury.assets` — never
/// reorder or retype across upgrades.
struct AssetConfig {
    address token;
    uint16 targetBps;
    bool registered;
}

/// Read-only valuation helpers extracted from AgentTreasury to keep the
/// implementation comfortably under the EIP-170 24,576-byte code limit.
/// Deployed once and DELEGATECALL-linked, so every function runs in the
/// treasury's context: `address(this)` is the treasury and the storage
/// pointers address its slots. All values are Chainlink marks via the
/// registry — swap slippage and pool fees are not modeled here.
library StockTreasuryValuation {
    uint16 private constant BPS_DENOM = 10000;

    function heldTokenValues(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IStockTokenRegistry registry
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

    /// Sum of all stock tokens held (at Chainlink marks) + idle stable.
    function nav(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 stable,
        IStockTokenRegistry registry
    ) public view returns (uint256 total) {
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) total += registry.valueOf(token, bal);
        }
        total += stable.balanceOf(address(this));
    }

    /// Oracle-mark estimate of a seller's stable proceeds: pro-rata idle plus
    /// each leg's slice valued at the Chainlink mark, minus the platform fee.
    /// The actual swap output differs by pool fees + slippage; callers treat
    /// this as a quote, and `withdrawAssetsTo`'s own `minStableOut` bounds the
    /// realized amount.
    function quoteWithdrawStable(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 stable,
        IStockTokenRegistry registry,
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
