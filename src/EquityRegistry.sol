// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IStateView} from "./interfaces/IStateView.sol";
import {V4PoolKey} from "./libraries/V4PoolKey.sol";
import {FullMath} from "./libraries/FullMath.sol";

/// @title EquityRegistry
/// @notice Platform allowlist + Chainlink oracle valuation + Uniswap-v4 route
/// resolution for REAL tokenized equities on Robinhood Chain.
///
/// This is the equity-basket sibling of {StockTokenRegistry}. The memecoin
/// `StockTokenRegistry` values via Uniswap v3 TWAP (memecoins have no feed);
/// this registry values via CHAINLINK because:
///   - every real equity has a live Chainlink feed (8 decimals);
///   - stock v4 pools carry NO oracle hook (hooks == address(0)), so an
///     on-chain v4 TWAP is impossible.
///
/// The valuation math (`valueOf`/`amountOf`, staleness guards, decimal scaling)
/// is REVIVED from the pre-pivot Chainlink `StockTokenRegistry` (git 620c571),
/// which was replaced when the `stock` class pivoted to memecoins. Routing is
/// new: instead of a packed v3 path we store the v4 pool's fee + tickSpacing and
/// expose a sorted {V4PoolKey.PoolKey} the treasury feeds to the forked router.
///
/// Robinhood Chain equity feeds are tagged `us_equities_24/5`: they FREEZE over
/// weekends, market holidays, and corporate actions. `maxPriceAge` must stay
/// generous (covers a long weekend + holiday) but valuation still reverts
/// `StalePrice` past it and `InvalidPrice` on a non-positive answer — never
/// marks a basket at a dead feed.
contract EquityRegistry is Ownable2Step {
    struct TokenInfo {
        address feed; // Chainlink AggregatorV3 (USD, 8-dec). Non-zero = registered sentinel.
        uint24 fee; // v4 fee tier (3000 or 10000)
        int24 tickSpacing; // 60 for 3000, 200 for 10000
        bool enabled;
        uint8 tokenDecimals; // 18 for stock tokens
        uint8 feedDecimals; // 8 for Chainlink USD feeds
        bool stableIsCurrency0; // cached: STABLE < token
        uint32 heartbeat; // per-feed max cadence (seconds); staleness = heartbeat + staleSlackSeconds
    }

    uint8 public constant STABLE_DECIMALS = 6;

    /// Default per-feed heartbeat for current equity/ETF feeds (24h).
    uint32 public constant DEFAULT_HEARTBEAT = 86_400;

    /// Grace window after an L2 sequencer restart during which prices are still
    /// distrusted (Chainlink's industry-standard 1h).
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    /// The stable value is denominated in and pools route from/to (USDG, 6-dec).
    address public immutable STABLE;

    /// Uniswap v4 StateView lens — read-only pool inspection for listing checks.
    IStateView public immutable STATE_VIEW;

    /// Chainlink L2 Sequencer Uptime Feed for Robinhood Chain (an Arbitrum Orbit
    /// L2 with a centralized sequencer). Guards every Chainlink read against a
    /// sequencer outage / restart backlog.
    ///
    /// ⚠️ OPTIONAL / OPT-OUT: set to `address(0)` to SKIP the sequencer check.
    /// A published uptime-feed address for Robinhood Chain could NOT be confirmed
    /// at authoring time (Chainlink's feed list is the source of truth —
    /// docs.chain.link/data-feeds/l2-sequencer-feeds + the Robinhood price-feeds
    /// page). Ops MUST wire the real address once published; DO NOT hardcode a
    /// guessed one. Deploying with address(0) ships WITHOUT sequencer protection.
    address public immutable SEQUENCER_UPTIME_FEED;

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    /// Floor on per-leg trade value (stable base units). A dust guard, not a venue rule.
    uint256 public minTradeStable = 1e6; // $1

    /// Small global cushion added to each feed's own `heartbeat` before a round
    /// is judged stale, so a feed that's merely a little late isn't falsely
    /// rejected. Staleness test is per-feed: `now - updatedAt > heartbeat + slack`.
    uint32 public staleSlackSeconds = 3600;

    /// Listing gate: require the pool to hold at least this much in-range
    /// liquidity when added. 0 = disabled (rely on manual curation).
    uint128 public minPoolLiquidity = 0;

    // ── Execution-pricing parameters (see EQUITY_EXECUTION_PRICING_SPEC.md) ──

    /// Realized-output slippage buffer (bps) when Chainlink is FRESH: a swap's
    /// `amountOutMinimum` = expected × (1 − slipBufferBps). Global default; ops
    /// should tune per market depth.
    uint16 public slipBufferBps = 300; // 3%

    /// WIDER buffer (bps) used when Chainlink is STALE and the floor is sized off
    /// (manipulable) spot instead — spot only loosens the floor, never sets the
    /// payout, so a wider band cannot be gamed to over-pay.
    uint16 public slipBufferStaleBps = 1000; // 10%

    /// Pre-trade divergence band (bps) between manipulable spot and FRESH
    /// Chainlink. 0 = DISABLED (like `minPoolLiquidity`). Ops should set a
    /// generous value (~500–1000) since equity pools legitimately drift from the
    /// underlying. When a leg exceeds the band, mint reverts `Diverged` and
    /// redeem skips the swap → settles that leg in-kind.
    uint16 public maxDivergenceBps = 0;

    event TokenAdded(address indexed token, address indexed feed, uint24 fee, int24 tickSpacing, bytes32 poolId);
    event TokenEnabledSet(address indexed token, bool enabled);
    event TokenFeedSet(address indexed token, address indexed feed);
    event TokenRouteSet(address indexed token, uint24 fee, int24 tickSpacing, bytes32 poolId);
    event TokenHeartbeatSet(address indexed token, uint32 previous, uint32 next);
    event MinTradeStableSet(uint256 previous, uint256 next);
    event StaleSlackSecondsSet(uint32 previous, uint32 next);
    event MinPoolLiquiditySet(uint128 previous, uint128 next);
    event SlipBufferBpsSet(uint16 previous, uint16 next);
    event SlipBufferStaleBpsSet(uint16 previous, uint16 next);
    event MaxDivergenceBpsSet(uint16 previous, uint16 next);

    error InvalidAddress();
    error InvalidRoute();
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error PoolNotInitialized(bytes32 poolId);
    error InsufficientLiquidity(bytes32 poolId, uint128 liquidity);
    error AmountTooLarge();
    error InvalidHeartbeat();
    /// L2 sequencer is reported down (or its round is uninitialized).
    error SequencerDown();
    /// L2 sequencer restarted within SEQUENCER_GRACE_PERIOD — prices distrusted.
    error SequencerGracePeriod();

    /// @param sequencerUptimeFeed_ Chainlink L2 Sequencer Uptime Feed, or
    /// `address(0)` to OPT OUT of the sequencer guard (ships without sequencer
    /// protection — see {SEQUENCER_UPTIME_FEED}).
    constructor(address owner_, address stable_, address stateView_, address sequencerUptimeFeed_)
        Ownable(owner_)
    {
        if (stable_ == address(0) || stateView_ == address(0)) revert InvalidAddress();
        STABLE = stable_;
        STATE_VIEW = IStateView(stateView_);
        SEQUENCER_UPTIME_FEED = sequencerUptimeFeed_;
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    /// @notice Register `token` with its Chainlink feed, per-feed `heartbeat`,
    /// and its direct v4 USDG↔token pool (fee tier + tickSpacing). Validates the
    /// pool is initialized and, if a floor is set, deep enough.
    /// @param heartbeat Max feed cadence (seconds); staleness = heartbeat +
    /// staleSlackSeconds. Must be > 0 (pass {DEFAULT_HEARTBEAT} = 86_400 for the
    /// current 24h equity/ETF feeds).
    function addToken(address token, address feed, uint24 fee, int24 tickSpacing, uint32 heartbeat)
        external
        onlyOwner
    {
        if (token == address(0) || feed == address(0)) revert InvalidAddress();
        if (tokens[token].feed != address(0)) revert AlreadyRegistered(token);
        if (fee == 0 || tickSpacing == 0) revert InvalidRoute();
        if (heartbeat == 0) revert InvalidHeartbeat();

        (bytes32 id, bool stable0) = _validatePool(token, fee, tickSpacing);

        tokens[token] = TokenInfo({
            feed: feed,
            fee: fee,
            tickSpacing: tickSpacing,
            enabled: true,
            tokenDecimals: IERC20Metadata(token).decimals(),
            feedDecimals: AggregatorV3Interface(feed).decimals(),
            stableIsCurrency0: stable0,
            heartbeat: heartbeat
        });
        tokenList.push(token);
        emit TokenAdded(token, feed, fee, tickSpacing, id);
    }

    function setHeartbeat(address token, uint32 heartbeat) external onlyOwner {
        if (tokens[token].feed == address(0)) revert NotRegistered(token);
        if (heartbeat == 0) revert InvalidHeartbeat();
        emit TokenHeartbeatSet(token, tokens[token].heartbeat, heartbeat);
        tokens[token].heartbeat = heartbeat;
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

    function setRoute(address token, uint24 fee, int24 tickSpacing) external onlyOwner {
        if (tokens[token].feed == address(0)) revert NotRegistered(token);
        if (fee == 0 || tickSpacing == 0) revert InvalidRoute();
        (bytes32 id, bool stable0) = _validatePool(token, fee, tickSpacing);
        TokenInfo storage info = tokens[token];
        info.fee = fee;
        info.tickSpacing = tickSpacing;
        info.stableIsCurrency0 = stable0;
        emit TokenRouteSet(token, fee, tickSpacing, id);
    }

    function setMinTradeStable(uint256 next) external onlyOwner {
        emit MinTradeStableSet(minTradeStable, next);
        minTradeStable = next;
    }

    function setStaleSlackSeconds(uint32 next) external onlyOwner {
        emit StaleSlackSecondsSet(staleSlackSeconds, next);
        staleSlackSeconds = next;
    }

    function setMinPoolLiquidity(uint128 next) external onlyOwner {
        emit MinPoolLiquiditySet(minPoolLiquidity, next);
        minPoolLiquidity = next;
    }

    function setSlipBufferBps(uint16 next) external onlyOwner {
        emit SlipBufferBpsSet(slipBufferBps, next);
        slipBufferBps = next;
    }

    function setSlipBufferStaleBps(uint16 next) external onlyOwner {
        emit SlipBufferStaleBpsSet(slipBufferStaleBps, next);
        slipBufferStaleBps = next;
    }

    function setMaxDivergenceBps(uint16 next) external onlyOwner {
        emit MaxDivergenceBpsSet(maxDivergenceBps, next);
        maxDivergenceBps = next;
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    function tokenCount() external view returns (uint256) {
        return tokenList.length;
    }

    /// @notice Allowlist gate. Disabling blocks NEW registrations only; existing
    /// holdings keep valuing so treasuries can always exit.
    function tokenExists(address token) external view returns (bool) {
        return tokens[token].enabled;
    }

    /// @notice Stable (6-dec) value of `amount` of `token` at the Chainlink mark.
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        (TokenInfo storage info, uint256 price) = _freshPrice(token);
        return (amount * price) / _scale(info);
    }

    /// @notice Token amount worth `stableValue` at the Chainlink mark (inverse of
    /// {valueOf}; used to size sell legs).
    function amountOf(address token, uint256 stableValue) external view returns (uint256) {
        if (stableValue == 0) return 0;
        (TokenInfo storage info, uint256 price) = _freshPrice(token);
        return (stableValue * _scale(info)) / price;
    }

    /// @notice Sorted v4 PoolKey for the direct STABLE↔token pool (hooks = 0).
    function poolKey(address token) public view returns (V4PoolKey.PoolKey memory) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        return V4PoolKey.build(STABLE, token, info.fee, info.tickSpacing);
    }

    function poolId(address token) external view returns (bytes32) {
        return V4PoolKey.toId(poolKey(token));
    }

    function stableIsCurrency0(address token) external view returns (bool) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        return info.stableIsCurrency0;
    }

    // ── Execution-pricing views ─────────────────────────────────────────────

    /// @notice True when the token's Chainlink mark is usable RIGHT NOW:
    /// the L2 sequencer is up (past grace), and the feed has a positive answer
    /// no older than its own `heartbeat + staleSlackSeconds`. Non-reverting — the
    /// treasury branches on it (fresh → Chainlink floors + mint enabled; not
    /// fresh → spot floors + mint paused) instead of catching a revert. False for
    /// an unregistered token.
    function isFeedFresh(address token) public view returns (bool) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) return false;
        if (!_sequencerOk()) return false;
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(info.feed).latestRoundData();
        // slither-disable-next-line timestamp
        return answer > 0 && block.timestamp - updatedAt <= uint256(info.heartbeat) + staleSlackSeconds;
    }

    /// @notice True when the L2 sequencer is up and past the restart grace
    /// window (or the guard is opted out via a zero uptime feed). Non-reverting.
    function isSequencerUp() external view returns (bool) {
        return _sequencerOk();
    }

    /// @notice Reverts `SequencerDown` / `SequencerGracePeriod` when the L2
    /// sequencer is unusable. No-op when the guard is opted out. The treasury
    /// calls this on the mint/NAV path so an outage surfaces as a DISTINCT error
    /// (vs. a weekend `MarketClosed`); redeem never calls it (execution-priced).
    function requireSequencerUp() external view {
        _requireSequencerUp();
    }

    /// @notice MANIPULABLE spot value (6-dec USDG) of `amount` of `token`, read
    /// from the v4 pool's `sqrtPriceX96` via StateView. USED ONLY to size a
    /// slippage floor / divergence band — NEVER as a payout or NAV price. A pool
    /// with no state (sqrtPrice 0) yields 0 (→ a zero floor, which the realized
    /// balance-delta check still bounds).
    function spotValueOf(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        bytes32 id = V4PoolKey.toId(V4PoolKey.build(STABLE, token, info.fee, info.tickSpacing));
        (uint160 sqrtPriceX96,,,) = STATE_VIEW.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;
        return _quoteFromSqrt(sqrtPriceX96, _u128(amount), token, STABLE);
    }

    /// @notice |spot − chainlink| / chainlink, in bps, for a reference unit
    /// (10^tokenDecimals). Reverts if the feed is not fresh (no reference).
    function currentDivergenceBps(address token) public view returns (uint256) {
        TokenInfo storage info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);
        uint256 unit = 10 ** uint256(info.tokenDecimals);
        uint256 cl = valueOf(token, unit);
        if (cl == 0) return type(uint256).max;
        uint256 spot = spotValueOf(token, unit);
        uint256 diff = spot > cl ? spot - cl : cl - spot;
        return (diff * 10000) / cl;
    }

    /// @notice Divergence-guard predicate. True (pass) when the guard is disabled
    /// (`maxDivergenceBps == 0`), the feed is stale (no Chainlink reference — the
    /// stale path handles safety via a wider spot floor), or spot is within the
    /// band of a fresh Chainlink mark.
    function divergenceOk(address token) external view returns (bool) {
        if (maxDivergenceBps == 0) return true;
        if (!isFeedFresh(token)) return true;
        return currentDivergenceBps(token) <= maxDivergenceBps;
    }

    // ─── Internal ─────────────────────────────────────────────────────────

    /// @dev Latest feed answer with the mandatory guards: the L2 sequencer must
    /// be up (past grace), the answer must be positive (feed fault), and the
    /// round must be within the feed's own `heartbeat + staleSlackSeconds`. Real
    /// equity feeds are 24/5, so weekends/holidays legitimately trip
    /// `StalePrice` — the treasury handles that by settling in-kind on exit
    /// (see {EquityTreasury.withdrawLtsTo}); it must never trade at a stale mark.
    function _freshPrice(address token) internal view returns (TokenInfo storage info, uint256 price) {
        info = tokens[token];
        if (info.feed == address(0)) revert NotRegistered(token);

        _requireSequencerUp();

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(info.feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(token);
        // slither-disable-next-line timestamp
        if (block.timestamp - updatedAt > uint256(info.heartbeat) + staleSlackSeconds) {
            revert StalePrice(token, updatedAt);
        }
        price = uint256(answer);
    }

    /// @dev Revert if the L2 sequencer is down or within its restart grace
    /// window. No-op when opted out (`SEQUENCER_UPTIME_FEED == address(0)`).
    /// Uptime-feed convention: answer 0 = up, 1 = down; `startedAt` is the round
    /// start (0 = uninitialized).
    function _requireSequencerUp() internal view {
        if (SEQUENCER_UPTIME_FEED == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(SEQUENCER_UPTIME_FEED).latestRoundData();
        if (answer != 0 || startedAt == 0) revert SequencerDown();
        // slither-disable-next-line timestamp
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
    }

    /// @dev Non-reverting sequencer check for {isFeedFresh}/{isSequencerUp}.
    function _sequencerOk() internal view returns (bool) {
        if (SEQUENCER_UPTIME_FEED == address(0)) return true;
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(SEQUENCER_UPTIME_FEED).latestRoundData();
        // slither-disable-next-line timestamp
        return answer == 0 && startedAt != 0 && block.timestamp - startedAt > SEQUENCER_GRACE_PERIOD;
    }

    /// @dev 10^(tokenDec + feedDec - stableDec): divisor taking (amount × price)
    /// to stable base units. For 18-dec token, 8-dec feed, 6-dec stable = 10^20.
    function _scale(TokenInfo storage info) internal view returns (uint256) {
        return 10 ** (uint256(info.tokenDecimals) + uint256(info.feedDecimals) - STABLE_DECIMALS);
    }

    /// @dev Confirm the declared v4 pool exists (initialized) and, if a floor is
    /// set, is deep enough. Returns its poolId and whether STABLE is currency0.
    function _validatePool(address token, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (bytes32 id, bool stable0)
    {
        V4PoolKey.PoolKey memory key = V4PoolKey.build(STABLE, token, fee, tickSpacing);
        id = V4PoolKey.toId(key);
        stable0 = key.currency0 == STABLE;

        (uint160 sqrtPriceX96,,,) = STATE_VIEW.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(id);

        if (minPoolLiquidity != 0) {
            uint128 liq = STATE_VIEW.getLiquidity(id);
            if (liq < minPoolLiquidity) revert InsufficientLiquidity(id, liq);
        }
    }

    /// @dev Quote `baseAmount` of `base` into `quote` from a v4 `sqrtPriceX96`
    /// (currency1-per-currency0 in Q96). Same ratio math as
    /// {OracleLibrary.getQuoteAtTick}, but taking the sqrt ratio straight from
    /// `slot0` (v4 pools expose sqrtPrice, not a tick oracle). SPOT — for floors
    /// and divergence only.
    function _quoteFromSqrt(uint160 sqrtRatioX96, uint128 baseAmount, address base, address quote)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = base < quote
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = base < quote
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert AmountTooLarge();
        return uint128(x);
    }
}
