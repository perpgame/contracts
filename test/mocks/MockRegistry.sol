// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStockTokenRegistry} from "../../src/interfaces/IStockTokenRegistry.sol";

/// Interface-level oracle stub for treasury/curve/factory tests.
///
/// The REAL StockTokenRegistry derives value from Uniswap TWAP tick math — that
/// is exercised end-to-end in StockTokenRegistryTwap.t.sol / StockTokenRegistryRoute.t.sol.
/// The treasury's own logic (deploy, rebalance steps, NAV, fees) only cares that
/// `valueOf`/`amountOf` behave like a consistent mark, so here we back them with
/// a plain per-token `mark` (stable base units per 1e18 of the 18-dec token) —
/// no ticks, no decimals gymnastics. `mark == 1e6` ⇒ "$1", value-conserving at
/// 18→6 decimals, keeping the NAV-conservation assertions exact.
///
/// `frozen` makes valuation revert, standing in for the old "stale Chainlink
/// feed" case (which is now "insufficient TWAP history" on the real registry).
contract MockRegistry is IStockTokenRegistry {
    struct Info {
        bool exists;
        bool enabled;
        bool frozen;
        uint256 mark; // stable base units per 1e18 token
        address intermediate;
        uint24 feeIn;
        uint24 feeOut;
    }

    address public immutable STABLE;
    mapping(address => Info) public infos;

    uint256 public minTradeStable = 1e6;
    uint32 public twapWindow = 1800;

    constructor(address stable_) {
        STABLE = stable_;
    }

    // ─── test hooks ─────────────────────────────────────────────────────────

    /// Register `token` with a swap route, defaulting to a $1 mark and enabled.
    function addToken(address token, address intermediate, uint24 feeIn, uint24 feeOut) external {
        infos[token] = Info({
            exists: true,
            enabled: true,
            frozen: false,
            mark: 1e6,
            intermediate: intermediate,
            feeIn: feeIn,
            feeOut: feeOut
        });
    }

    function setMark(address token, uint256 mark) external {
        infos[token].mark = mark;
    }

    function setEnabled(address token, bool enabled) external {
        infos[token].enabled = enabled;
    }

    function setFrozen(address token, bool frozen) external {
        infos[token].frozen = frozen;
    }

    function setMinTradeStable(uint256 v) external {
        minTradeStable = v;
    }

    // ─── IStockTokenRegistry ──────────────────────────────────────────────────

    function tokenExists(address token) external view returns (bool) {
        return infos[token].enabled;
    }

    function poolFee(address token) external view returns (uint24) {
        return infos[token].feeIn;
    }

    function buyPath(address token) external view returns (bytes memory) {
        Info storage i = infos[token];
        if (i.intermediate == address(0)) {
            return abi.encodePacked(STABLE, i.feeIn, token);
        }
        return abi.encodePacked(STABLE, i.feeIn, i.intermediate, i.feeOut, token);
    }

    function sellPath(address token) external view returns (bytes memory) {
        Info storage i = infos[token];
        if (i.intermediate == address(0)) {
            return abi.encodePacked(token, i.feeIn, STABLE);
        }
        return abi.encodePacked(token, i.feeOut, i.intermediate, i.feeIn, STABLE);
    }

    function valueOf(address token, uint256 amount) external view returns (uint256) {
        if (amount == 0) return 0;
        Info storage i = infos[token];
        require(i.exists, "MockRegistry: not registered");
        require(!i.frozen, "MockRegistry: stale");
        return (amount * i.mark) / 1e18;
    }

    function amountOf(address token, uint256 stableValue) external view returns (uint256) {
        if (stableValue == 0) return 0;
        Info storage i = infos[token];
        require(i.exists, "MockRegistry: not registered");
        require(!i.frozen, "MockRegistry: stale");
        return (stableValue * 1e18) / i.mark;
    }
}
