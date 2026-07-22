// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEquityRegistry} from "../interfaces/IEquityRegistry.sol";
import {IUniversalRouterForked} from "../interfaces/IUniversalRouterForked.sol";
import {IPermit2} from "../interfaces/IPermit2.sol";
import {V4PoolKey} from "./V4PoolKey.sol";
import {V4SwapEncoder} from "./V4SwapEncoder.sol";
import {AssetConfig} from "../EquityTreasuryValuation.sol";

/// @title EquityTreasuryExec
/// @notice Staleness-tolerant marks, slippage floors, and the Uniswap v4
/// (forked UniversalRouter + Permit2) swap primitive for {EquityTreasury},
/// extracted to keep the implementation under the EIP-170 24,576-byte limit.
/// Deployed once and DELEGATECALL-linked, so every function runs in the
/// treasury's storage context (`address(this)` is the treasury, and its token
/// balances / Permit2 allowances are the ones read and mutated).
///
/// This holds the equity-specific execution delta vs {StockTreasury} (v4 vs v3);
/// the treasury keeps only thin wrappers that forward to these functions, so its
/// call sites and behavior are unchanged.
library EquityTreasuryExec {
    using SafeERC20 for IERC20;

    uint16 private constant BPS_DENOM = 10000;

    /// Canonical Permit2 (AllowanceTransfer) — same address the treasury reads.
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint48 private constant PERMIT2_EXPIRATION_BUFFER = 300;

    error SlippageExceeded();
    error AmountTooLarge();

    /// @dev Stable value of `tokenAmt`: Chainlink if fresh, else spot.
    function markValue(IEquityRegistry registry, address token, uint256 tokenAmt) public view returns (uint256) {
        if (registry.isFeedFresh(token)) return registry.valueOf(token, tokenAmt);
        return registry.spotValueOf(token, tokenAmt);
    }

    /// @dev Token amount worth `stableValue`: Chainlink inverse if fresh, else a
    /// spot inverse (assumes 18-dec equity tokens — the only class here).
    function markAmount(IEquityRegistry registry, address token, uint256 stableValue) public view returns (uint256) {
        if (registry.isFeedFresh(token)) return registry.amountOf(token, stableValue);
        uint256 unitValue = registry.spotValueOf(token, 1e18); // USDG per 1e18 token
        if (unitValue == 0) return 0;
        return (stableValue * 1e18) / unitValue;
    }

    /// @dev SELL floor (stable out): max(caller floor, expected × (1 − buffer)),
    /// buffer wider when priced off spot.
    function sellFloor(IEquityRegistry registry, address token, uint256 expectedStableOut, uint256 callerFloor)
        public
        view
        returns (uint256)
    {
        uint16 buffer = registry.isFeedFresh(token) ? registry.slipBufferBps() : registry.slipBufferStaleBps();
        uint256 bufFloor = (expectedStableOut * (BPS_DENOM - buffer)) / BPS_DENOM;
        return callerFloor > bufFloor ? callerFloor : bufFloor;
    }

    /// @dev BUY floor (token out): max(caller floor, expected × (1 − buffer)).
    function buyFloor(IEquityRegistry registry, address token, uint256 growStable, uint256 callerFloor)
        public
        view
        returns (uint256)
    {
        uint256 expectedToken = markAmount(registry, token, growStable);
        uint16 buffer = registry.isFeedFresh(token) ? registry.slipBufferBps() : registry.slipBufferStaleBps();
        uint256 bufFloor = (expectedToken * (BPS_DENOM - buffer)) / BPS_DENOM;
        return callerFloor > bufFloor ? callerFloor : bufFloor;
    }

    /// @dev Rebalance NAV using staleness-tolerant marks (not pure Chainlink):
    /// sum of held legs at {markValue} + idle stable.
    function rebalanceNav(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 stable,
        IEquityRegistry registry
    ) public view returns (uint256 total) {
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) total += markValue(registry, token, bal);
        }
        total += stable.balanceOf(address(this));
    }

    /// @dev Exact-in v4 swap through the forked UniversalRouter. `isBuy` true →
    /// spending `stable` for `equityToken`; false → the reverse. Realized output
    /// is a balance delta (the router's execute() returns nothing); reverts
    /// SlippageExceeded if it falls below `minOut`. Funding is Permit2.
    function v4ExactInput(
        IEquityRegistry registry,
        IUniversalRouterForked router,
        address stable,
        address equityToken,
        uint256 amountIn,
        uint256 minOut,
        bool isBuy
    ) public returns (uint256 out) {
        (address tokenIn, address tokenOut) = isBuy ? (stable, equityToken) : (equityToken, stable);
        uint128 amtIn = _u128(amountIn);

        V4PoolKey.PoolKey memory key = registry.poolKey(equityToken);
        bool zeroForOne = tokenIn == key.currency0;

        // Permit2 funding: one-time max token→Permit2 ERC-20 allowance, then a
        // per-swap Permit2→router allowance sized to exactly this input.
        if (IERC20(tokenIn).allowance(address(this), PERMIT2) < amtIn) {
            IERC20(tokenIn).forceApprove(PERMIT2, type(uint256).max);
        }
        IPermit2(PERMIT2).approve(
            tokenIn, address(router), amtIn, uint48(block.timestamp) + PERMIT2_EXPIRATION_BUFFER
        );

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        (bytes memory commands, bytes[] memory inputs) =
            V4SwapEncoder.encodeExactInSingle(key, zeroForOne, tokenIn, tokenOut, amtIn, _u128(minOut), 0);
        // slither-disable-next-line reentrancy-events
        router.execute(commands, inputs, block.timestamp);

        out = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (out < minOut) revert SlippageExceeded();
    }

    function _u128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert AmountTooLarge();
        return uint128(x);
    }
}
