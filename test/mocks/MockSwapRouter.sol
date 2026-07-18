// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockAggregator} from "./MockAggregator.sol";

/// Uniswap v3 SwapRouter02 stand-in. Converts between the 6-decimal stable and
/// 18-decimal stock tokens AT THE REGISTERED FEED PRICE, so with `feeBps == 0`
/// (the default) swaps are exactly value-conserving at the oracle mark and the
/// nav-conservation tests stay exact. Individual tests set `feeBps` to model
/// pool fees + impact, `revertAll` to model a dead router, or a per-token
/// revert to model one dead/paused pool.
///
/// Pays tokenOut from its own balance — tests pre-fund it with stable and
/// stock tokens. Pulls tokenIn from the caller like the real router.
contract MockSwapRouter is ISwapRouter02 {
    using SafeERC20 for IERC20;

    address public immutable STABLE;

    /// Stock token → its price feed (same feed the registry uses).
    mapping(address => MockAggregator) public feeds;

    /// Swap fee in bps applied to amountOut. Default 0 → exact conversion.
    uint256 public feeBps;

    /// When true every swap reverts — a globally dead router/pool.
    bool public revertAll;

    /// Per-stock-token dead pool flag.
    mapping(address => bool) public revertToken;

    constructor(address stable_) {
        STABLE = stable_;
    }

    // ─── test hooks ─────────────────────────────────────────────────────────

    function setFeed(address token, MockAggregator feed) external {
        feeds[token] = feed;
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function setRevertAll(bool r) external {
        revertAll = r;
    }

    function setRevertToken(address token, bool r) external {
        revertToken[token] = r;
    }

    // ─── ISwapRouter02 ──────────────────────────────────────────────────────

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        amountOut = _swap(p.tokenIn, p.tokenOut, p.amountIn, p.amountOutMinimum, p.recipient);
    }

    /// Multi-hop exact-input. Only the endpoints matter to the mock's economic
    /// model: the packed path's first 20 bytes are tokenIn, its last 20 bytes
    /// are tokenOut, and the intermediate hop(s) are priced through as a single
    /// end-to-end conversion (same feed-priced math as exactInputSingle). The
    /// interior fee/token bytes don't affect the mock's result.
    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        address tokenIn = _addressAt(p.path, 0);
        address tokenOut = _addressAt(p.path, p.path.length - 20);
        amountOut = _swap(tokenIn, tokenOut, p.amountIn, p.amountOutMinimum, p.recipient);
    }

    /// Feed-priced conversion shared by both entrypoints. tokenIn/tokenOut are
    /// the path endpoints; exactly one of them is STABLE, the other the stock.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMinimum, address recipient)
        internal
        returns (uint256 amountOut)
    {
        require(!revertAll, "router dead");
        address stock = tokenIn == STABLE ? tokenOut : tokenIn;
        require(!revertToken[stock], "pool dead");
        MockAggregator feed = feeds[stock];
        require(address(feed) != address(0), "no feed");

        (, int256 answer,,,) = feed.latestRoundData();
        require(answer > 0, "bad price");
        uint256 price = uint256(answer);
        // Stock tokens are 18-dec, stable is 6-dec:
        // divisor taking (tokenAmount × price) down to stable base units.
        uint256 scale = 10 ** (18 + uint256(feed.decimals()) - 6);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (tokenIn == STABLE) {
            amountOut = (amountIn * scale) / price; // stable → stock
        } else {
            amountOut = (amountIn * price) / scale; // stock → stable
        }
        amountOut -= (amountOut * feeBps) / 10000;

        require(amountOut >= amountOutMinimum, "Too little received");
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }

    /// Read the 20-byte address at `offset` in a Uniswap v3 packed path.
    function _addressAt(bytes memory path, uint256 offset) internal pure returns (address addr) {
        require(path.length >= offset + 20, "bad path");
        // The word starting at `offset` has the 20 address bytes in its high
        // bytes; shift right by 12 bytes (96 bits) to right-align them.
        assembly {
            addr := shr(96, mload(add(add(path, 0x20), offset)))
        }
    }
}
