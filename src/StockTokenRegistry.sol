// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";

/// Platform allowlist + Uniswap-TWAP valuation + swap routing for the tokens a
/// treasury may hold. Originally built for Chainlink-fed tokenized stocks; the
/// memecoin universe on Robinhood Chain has NO oracle feeds, so valuation is
/// derived from each token's own Uniswap v3 pools via a time-weighted average
/// price (TWAP):
///   - `tokenExists` gates which tokens a treasury may hold;
///   - `valueOf`/`amountOf` convert between token amounts and 6-decimal stable
///     value using the mean tick over `twapWindow` seconds;
///   - `buyPath`/`sellPath` give the treasury the Uniswap v3 swap route.
///
/// WHY TWAP, NOT SPOT: `AgentCurve` mints and redeems basket shares at NAV, so
/// the price feeding NAV must not be movable inside a single transaction. A
/// spot tick can be shoved by a flash-loan swap and read mid-transaction; a mean
/// over `twapWindow` seconds cannot. `minTwapWindow` additionally refuses to
/// price against a pool whose oracle is too fresh (too little history) to trust,
/// and `minPoolLiquidity` gates listing to pools deep enough to resist a shove.
///
/// ROUTING: most tokens have NO direct stable pool — liquidity is two-hop through
/// an intermediate (WETH): stable ⇄ WETH ⇄ token. Each token stores an
/// `intermediate` (address(0) = a direct stable↔token pool), the two fee tiers,
/// and the two pool addresses used BOTH for path building and TWAP valuation.
contract StockTokenRegistry is Ownable2Step {
    struct TokenInfo {
        bool enabled;
        /// Swap/pricing route. intermediate == address(0) → direct stable↔token
        /// pool. Otherwise two-hop: stable↔intermediate, then intermediate↔token.
        address intermediate;
        uint24 feeIn; // stable ↔ (intermediate|token)
        uint24 feeOut; // intermediate ↔ token (two-hop only)
        /// The stable-side pool (STABLE↔intermediate, or STABLE↔token if direct).
        /// Non-zero here is the "registered" sentinel.
        address poolIn;
        /// The token-side pool (intermediate↔token); address(0) when direct.
        address poolOut;
    }

    uint8 public constant STABLE_DECIMALS = 6;

    /// The stable the paths route from/to and value is denominated in (USDG).
    address public immutable STABLE;

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    /// Floor on per-leg trade value (stable base units). A dust guard for swap
    /// legs, not a venue rule.
    uint256 public minTradeStable = 1e6; // $1

    /// Target TWAP window. NAV is priced off the mean tick over this many seconds.
    uint32 public twapWindow = 1800; // 30 min

    /// A pool must have at least this much oracle history or it is refused for
    /// pricing — protects against pricing off a too-fresh (thin-history) oracle.
    uint32 public minTwapWindow = 600; // 10 min

    /// Listing gate: a token's token-side pool must have at least this much
    /// in-range liquidity to be added. 0 = disabled (rely on manual curation).
    uint128 public minPoolLiquidity = 0;

    event TokenAdded(address indexed token, address intermediate, uint24 feeIn, uint24 feeOut, address poolIn, address poolOut);
    event TokenEnabledSet(address indexed token, bool enabled);
    event TokenRouteSet(address indexed token, address intermediate, uint24 feeIn, uint24 feeOut, address poolIn, address poolOut);
    event MinTradeStableSet(uint256 previous, uint256 next);
    event TwapWindowSet(uint32 previous, uint32 next);
    event MinTwapWindowSet(uint32 previous, uint32 next);
    event MinPoolLiquiditySet(uint128 previous, uint128 next);

    error InvalidAddress();
    error InvalidRoute();
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error PoolMismatch(address pool);
    error InsufficientLiquidity(address pool, uint128 liquidity);
    error InsufficientHistory(address pool, uint32 available);
    error AmountTooLarge();
    error InvalidWindow();

    constructor(address owner_, address stable_) Ownable(owner_) {
        if (stable_ == address(0)) revert InvalidAddress();
        STABLE = stable_;
    }

    /// Register a token with its Uniswap route + pricing pools.
    /// intermediate == address(0) → direct stable↔token pool at feeIn via
    /// poolIn (poolOut must be 0). Otherwise stable↔intermediate @ feeIn via
    /// poolIn, then intermediate↔token @ feeOut via poolOut.
    function addToken(
        address token,
        address intermediate,
        uint24 feeIn,
        uint24 feeOut,
        address poolIn,
        address poolOut
    ) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        if (tokens[token].poolIn != address(0)) revert AlreadyRegistered(token);
        _validateRoute(token, intermediate, feeIn, feeOut, poolIn, poolOut);

        tokens[token] = TokenInfo({
            enabled: true,
            intermediate: intermediate,
            feeIn: feeIn,
            feeOut: feeOut,
            poolIn: poolIn,
            poolOut: poolOut
        });
        tokenList.push(token);
        emit TokenAdded(token, intermediate, feeIn, feeOut, poolIn, poolOut);
    }

    function setEnabled(address token, bool enabled) external onlyOwner {
        if (tokens[token].poolIn == address(0)) revert NotRegistered(token);
        tokens[token].enabled = enabled;
        emit TokenEnabledSet(token, enabled);
    }

    function setRoute(
        address token,
        address intermediate,
        uint24 feeIn,
        uint24 feeOut,
        address poolIn,
        address poolOut
    ) external onlyOwner {
        if (tokens[token].poolIn == address(0)) revert NotRegistered(token);
        _validateRoute(token, intermediate, feeIn, feeOut, poolIn, poolOut);
        TokenInfo storage info = tokens[token];
        info.intermediate = intermediate;
        info.feeIn = feeIn;
        info.feeOut = feeOut;
        info.poolIn = poolIn;
        info.poolOut = poolOut;
        emit TokenRouteSet(token, intermediate, feeIn, feeOut, poolIn, poolOut);
    }

    function setMinTradeStable(uint256 next) external onlyOwner {
        emit MinTradeStableSet(minTradeStable, next);
        minTradeStable = next;
    }

    function setTwapWindow(uint32 next) external onlyOwner {
        if (next == 0 || next < minTwapWindow) revert InvalidWindow();
        emit TwapWindowSet(twapWindow, next);
        twapWindow = next;
    }

    function setMinTwapWindow(uint32 next) external onlyOwner {
        if (next == 0 || next > twapWindow) revert InvalidWindow();
        emit MinTwapWindowSet(minTwapWindow, next);
        minTwapWindow = next;
    }

    function setMinPoolLiquidity(uint128 next) external onlyOwner {
        emit MinPoolLiquiditySet(minPoolLiquidity, next);
        minPoolLiquidity = next;
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
        if (info.poolIn == address(0)) revert NotRegistered(token);
        return info.feeIn;
    }

    /// Packed Uniswap v3 path for a BUY (STABLE → token). One hop if direct,
    /// two hops through `intermediate` otherwise.
    function buyPath(address token) external view returns (bytes memory) {
        TokenInfo storage info = tokens[token];
        if (info.poolIn == address(0)) revert NotRegistered(token);
        if (info.intermediate == address(0)) {
            return abi.encodePacked(STABLE, info.feeIn, token);
        }
        return abi.encodePacked(STABLE, info.feeIn, info.intermediate, info.feeOut, token);
    }

    /// Packed Uniswap v3 path for a SELL (token → STABLE) — the reverse route.
    function sellPath(address token) external view returns (bytes memory) {
        TokenInfo storage info = tokens[token];
        if (info.poolIn == address(0)) revert NotRegistered(token);
        if (info.intermediate == address(0)) {
            return abi.encodePacked(token, info.feeIn, STABLE);
        }
        return abi.encodePacked(token, info.feeOut, info.intermediate, info.feeIn, STABLE);
    }

    /// Stable (6-dec) value of `amount` of `token` at the TWAP mark. For a
    /// two-hop token we compose the two pools' TWAPs: token → intermediate,
    /// then intermediate → stable.
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        TokenInfo storage info = _registered(token);
        if (info.intermediate == address(0)) {
            return _quote(info.poolIn, token, STABLE, amount);
        }
        uint256 mid = _quote(info.poolOut, token, info.intermediate, amount);
        return _quote(info.poolIn, info.intermediate, STABLE, mid);
    }

    /// Token amount worth `stableValue` at the TWAP mark (inverse of valueOf).
    function amountOf(address token, uint256 stableValue) external view returns (uint256) {
        if (stableValue == 0) return 0;
        TokenInfo storage info = _registered(token);
        if (info.intermediate == address(0)) {
            return _quote(info.poolIn, STABLE, token, stableValue);
        }
        uint256 mid = _quote(info.poolIn, STABLE, info.intermediate, stableValue);
        return _quote(info.poolOut, info.intermediate, token, mid);
    }

    function _registered(address token) internal view returns (TokenInfo storage info) {
        info = tokens[token];
        if (info.poolIn == address(0)) revert NotRegistered(token);
    }

    /// TWAP-quote `baseAmount` of `base` into `quote` using `pool`'s mean tick.
    function _quote(address pool, address base, address quote, uint256 baseAmount) internal view returns (uint256) {
        int24 meanTick = _consult(pool);
        return OracleLibrary.getQuoteAtTick(meanTick, _u128(baseAmount), base, quote);
    }

    /// Mean tick over min(twapWindow, available history), rejecting pools whose
    /// oracle history is shorter than `minTwapWindow`.
    function _consult(address pool) internal view returns (int24) {
        uint32 oldest = OracleLibrary.getOldestObservationSecondsAgo(pool);
        if (oldest < minTwapWindow) revert InsufficientHistory(pool, oldest);
        uint32 window = twapWindow;
        if (oldest < window) window = oldest;
        return OracleLibrary.consult(pool, window);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert AmountTooLarge();
        return uint128(x);
    }

    /// Validate that the declared pools actually pair the declared tokens at the
    /// declared fees, and (if a floor is set) that the token-side pool is deep
    /// enough to list.
    function _validateRoute(
        address token,
        address intermediate,
        uint24 feeIn,
        uint24 feeOut,
        address poolIn,
        address poolOut
    ) internal view {
        if (poolIn == address(0)) revert InvalidRoute();
        if (feeIn == 0) revert InvalidRoute();

        if (intermediate == address(0)) {
            // Direct STABLE↔token pool.
            if (poolOut != address(0)) revert InvalidRoute();
            _checkPool(poolIn, STABLE, token, feeIn);
            _checkLiquidity(poolIn);
        } else {
            // Two-hop STABLE↔intermediate↔token.
            if (poolOut == address(0) || feeOut == 0) revert InvalidRoute();
            _checkPool(poolIn, STABLE, intermediate, feeIn);
            _checkPool(poolOut, intermediate, token, feeOut);
            _checkLiquidity(poolOut);
        }
    }

    function _checkPool(address pool, address a, address b, uint24 fee) internal view {
        address t0 = IUniswapV3Pool(pool).token0();
        address t1 = IUniswapV3Pool(pool).token1();
        bool pairOk = (t0 == a && t1 == b) || (t0 == b && t1 == a);
        if (!pairOk || IUniswapV3Pool(pool).fee() != fee) revert PoolMismatch(pool);
    }

    function _checkLiquidity(address pool) internal view {
        if (minPoolLiquidity == 0) return;
        uint128 liq = IUniswapV3Pool(pool).liquidity();
        if (liq < minPoolLiquidity) revert InsufficientLiquidity(pool, liq);
    }
}
