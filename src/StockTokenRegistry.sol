// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// Platform allowlist + oracle valuation for tradeable stock tokens. Replaces
/// Bounce's factory allowlist and LT exchange rates: `tokenExists` gates which
/// tokens a treasury may hold, and `valueOf`/`amountOf` convert between token
/// amounts and 6-decimal stable value via each token's Chainlink feed.
///
/// Robinhood Chain equity feeds are 24/5 (heartbeat 86400s, 0.5% deviation)
/// and freeze over weekends, market holidays, and corporate actions, so the
/// staleness window must stay generous. `maxPriceAge` is owner-tunable;
/// valuations revert `StalePrice` past it. A sequencer-uptime-feed check can
/// be layered in here later without touching the treasuries.
contract StockTokenRegistry is Ownable2Step {
    struct TokenInfo {
        address feed;
        uint24 poolFee; // Uniswap v3 fee tier of the token's stable pool
        bool enabled;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    uint8 public constant STABLE_DECIMALS = 6;

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    /// Floor on per-leg trade value (stable base units). Not a venue rule like
    /// Bounce's minTransactionSize — just a dust guard for swap legs.
    uint256 public minTradeStable = 1e6; // $1

    /// Max accepted feed age. Default covers a long weekend + market holiday.
    uint256 public maxPriceAge = 5 days;

    event TokenAdded(address indexed token, address indexed feed, uint24 poolFee);
    event TokenEnabledSet(address indexed token, bool enabled);
    event TokenFeedSet(address indexed token, address indexed feed);
    event TokenPoolFeeSet(address indexed token, uint24 poolFee);
    event MinTradeStableSet(uint256 previous, uint256 next);
    event MaxPriceAgeSet(uint256 previous, uint256 next);

    error InvalidAddress();
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error ZeroAmount();

    constructor(address owner_) Ownable(owner_) {}

    function addToken(address token, address feed, uint24 poolFee) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert InvalidAddress();
        if (tokens[token].feed != address(0)) revert AlreadyRegistered(token);

        tokens[token] = TokenInfo({
            feed: feed,
            poolFee: poolFee,
            enabled: true,
            tokenDecimals: IERC20Metadata(token).decimals(),
            feedDecimals: AggregatorV3Interface(feed).decimals()
        });
        tokenList.push(token);
        emit TokenAdded(token, feed, poolFee);
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

    function setPoolFee(address token, uint24 poolFee) external onlyOwner {
        if (tokens[token].feed == address(0)) revert NotRegistered(token);
        tokens[token].poolFee = poolFee;
        emit TokenPoolFeeSet(token, poolFee);
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

    /// Allowlist gate for treasury registration (`ltExists` analog). Disabling
    /// a token blocks NEW registrations only; existing holdings keep valuing
    /// through `valueOf` so treasuries already holding it can exit.
    function tokenExists(address token) external view returns (bool) {
        return tokens[token].enabled;
    }

    function poolFee(address token) external view returns (uint24) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        return info.poolFee;
    }

    /// Stable (6-dec) value of `amount` of `token` at the Chainlink mark.
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        (TokenInfo storage info, uint256 price) = _freshPrice(token);
        return (amount * price) / _scale(info);
    }

    /// Token amount worth `stableValue` at the Chainlink mark (inverse of
    /// `valueOf`, used to size sell legs).
    function amountOf(address token, uint256 stableValue) external view returns (uint256) {
        if (stableValue == 0) return 0;
        (TokenInfo storage info, uint256 price) = _freshPrice(token);
        return (stableValue * _scale(info)) / price;
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
