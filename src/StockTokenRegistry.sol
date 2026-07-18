// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// Platform allowlist + oracle valuation + swap routing for tradeable stock
/// tokens. Replaces Bounce's factory allowlist and LT exchange rates:
///   - `tokenExists` gates which tokens a treasury may hold;
///   - `valueOf`/`amountOf` convert between token amounts and 6-decimal stable
///     value via each token's Chainlink feed;
///   - `buyPath`/`sellPath` give the treasury the Uniswap v3 swap route.
///
/// ROUTING: most stock tokens have NO direct stable pool — liquidity is two-hop
/// through an intermediate (WETH): stable ⇄ WETH ⇄ token. Each token stores an
/// `intermediate` (address(0) = a direct stable↔token pool) plus the two fee
/// tiers (`feeIn` = stable↔first hop, `feeOut` = intermediate↔token). The
/// registry builds the packed v3 path on-chain so the treasury just calls
/// `exactInput(path)`; a direct token is simply a one-hop path.
///
/// Robinhood Chain equity feeds are 24/5 and freeze over weekends, market
/// holidays, and corporate actions, so `maxPriceAge` stays generous.
contract StockTokenRegistry is Ownable2Step {
    struct TokenInfo {
        address feed;
        bool enabled;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        /// Swap route. intermediate == address(0) → direct stable↔token pool at
        /// `feeIn`. Otherwise two-hop: stable↔intermediate at `feeIn`, then
        /// intermediate↔token at `feeOut`.
        address intermediate;
        uint24 feeIn;
        uint24 feeOut;
    }

    uint8 public constant STABLE_DECIMALS = 6;

    /// The stable the paths route from/to (USDG). Immutable — set once so the
    /// registry can build swap paths without a per-call arg.
    address public immutable STABLE;

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    /// Floor on per-leg trade value (stable base units). A dust guard for swap
    /// legs, not a venue rule.
    uint256 public minTradeStable = 1e6; // $1

    /// Max accepted feed age. Default covers a long weekend + market holiday.
    uint256 public maxPriceAge = 5 days;

    event TokenAdded(address indexed token, address indexed feed, address intermediate, uint24 feeIn, uint24 feeOut);
    event TokenEnabledSet(address indexed token, bool enabled);
    event TokenFeedSet(address indexed token, address indexed feed);
    event TokenRouteSet(address indexed token, address intermediate, uint24 feeIn, uint24 feeOut);
    event MinTradeStableSet(uint256 previous, uint256 next);
    event MaxPriceAgeSet(uint256 previous, uint256 next);

    error InvalidAddress();
    error InvalidRoute();
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error ZeroAmount();

    constructor(address owner_, address stable_) Ownable(owner_) {
        if (stable_ == address(0)) revert InvalidAddress();
        STABLE = stable_;
    }

    /// Register a token with its Chainlink feed and Uniswap route.
    /// intermediate == address(0) → direct stable↔token pool at feeIn (feeOut
    /// ignored). Otherwise stable↔intermediate @ feeIn, intermediate↔token @ feeOut.
    function addToken(address token, address feed, address intermediate, uint24 feeIn, uint24 feeOut)
        external
        onlyOwner
    {
        if (token == address(0) || feed == address(0)) revert InvalidAddress();
        if (tokens[token].feed != address(0)) revert AlreadyRegistered(token);
        _validateRoute(intermediate, feeIn, feeOut);

        tokens[token] = TokenInfo({
            feed: feed,
            enabled: true,
            tokenDecimals: IERC20Metadata(token).decimals(),
            feedDecimals: AggregatorV3Interface(feed).decimals(),
            intermediate: intermediate,
            feeIn: feeIn,
            feeOut: feeOut
        });
        tokenList.push(token);
        emit TokenAdded(token, feed, intermediate, feeIn, feeOut);
    }

    function setEnabled(address token, bool enabled) external onlyOwner {
        if (tokens[token].feed == address(0)) revert NotRegistered(token);
        tokens[token].enabled = enabled;
        emit TokenEnabledSet(token, enabled);
    }

    function setFeed(address token, address feed) external onlyOwner {
        if (feed == address(0)) revert InvalidAddress();
        if (tokens[token].feed == address(0)) revert NotRegistered(token);
        tokens[token].feed = feed;
        tokens[token].feedDecimals = AggregatorV3Interface(feed).decimals();
        emit TokenFeedSet(token, feed);
    }

    function setRoute(address token, address intermediate, uint24 feeIn, uint24 feeOut) external onlyOwner {
        if (tokens[token].feed == address(0)) revert NotRegistered(token);
        _validateRoute(intermediate, feeIn, feeOut);
        tokens[token].intermediate = intermediate;
        tokens[token].feeIn = feeIn;
        tokens[token].feeOut = feeOut;
        emit TokenRouteSet(token, intermediate, feeIn, feeOut);
    }

    function setMinTradeStable(uint256 next) external onlyOwner {
        emit MinTradeStableSet(minTradeStable, next);
        minTradeStable = next;
    }

    function setMaxPriceAge(uint256 next) external onlyOwner {
        emit MaxPriceAgeSet(maxPriceAge, next);
        maxPriceAge = next;
    }

    function tokenCount() external view returns (uint256) {
        return tokenList.length;
    }

    /// Allowlist gate for treasury registration. Disabling blocks NEW
    /// registrations only; existing holdings keep valuing so treasuries can exit.
    function tokenExists(address token) external view returns (bool) {
        return tokens[token].enabled;
    }

    /// The first-hop fee tier (kept for display/back-compat; routing uses the
    /// full path from buyPath/sellPath).
    function poolFee(address token) external view returns (uint24) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        return info.feeIn;
    }

    /// Packed Uniswap v3 path for a BUY (STABLE → token). One hop if direct,
    /// two hops through `intermediate` otherwise.
    function buyPath(address token) external view returns (bytes memory) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        if (info.intermediate == address(0)) {
            return abi.encodePacked(STABLE, info.feeIn, token);
        }
        return abi.encodePacked(STABLE, info.feeIn, info.intermediate, info.feeOut, token);
    }

    /// Packed Uniswap v3 path for a SELL (token → STABLE) — the reverse route.
    function sellPath(address token) external view returns (bytes memory) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        if (info.intermediate == address(0)) {
            return abi.encodePacked(token, info.feeIn, STABLE);
        }
        return abi.encodePacked(token, info.feeOut, info.intermediate, info.feeIn, STABLE);
    }

    /// Stable (6-dec) value of `amount` of `token` at the Chainlink mark.
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        (TokenInfo storage info, uint256 price) = _freshPrice(token);
        return (amount * price) / _scale(info);
    }

    /// Token amount worth `stableValue` at the Chainlink mark (inverse of valueOf).
    function amountOf(address token, uint256 stableValue) external view returns (uint256) {
        if (stableValue == 0) return 0;
        (TokenInfo storage info, uint256 price) = _freshPrice(token);
        return (stableValue * _scale(info)) / price;
    }

    function _validateRoute(address intermediate, uint24 feeIn, uint24 feeOut) internal pure {
        // feeIn is always the first hop; feeOut only matters for a two-hop route.
        if (feeIn == 0) revert InvalidRoute();
        if (intermediate != address(0) && feeOut == 0) revert InvalidRoute();
    }

    function _freshPrice(address token) internal view returns (TokenInfo storage info, uint256 price) {
        info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(info.feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(token);
        // slither-disable-next-line timestamp
        if (block.timestamp > updatedAt + maxPriceAge) revert StalePrice(token, updatedAt);
        price = uint256(answer);
    }

    /// 10^(tokenDec + feedDec - 6): divisor taking (amount × price) to stable base.
    function _scale(TokenInfo storage info) internal view returns (uint256) {
        return 10 ** (uint256(info.tokenDecimals) + uint256(info.feedDecimals) - STABLE_DECIMALS);
    }
}
