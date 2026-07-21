// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IEquityRegistry} from "./interfaces/IEquityRegistry.sol";
import {IUniversalRouterForked} from "./interfaces/IUniversalRouterForked.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {AgentCurve} from "./AgentCurve.sol";
import {V4PoolKey} from "./libraries/V4PoolKey.sol";
import {V4SwapEncoder} from "./libraries/V4SwapEncoder.sol";
import {EquityTreasuryValuation, AssetConfig} from "./EquityTreasuryValuation.sol";

interface IEquityTreasuryFactory {
    function paused() external view returns (bool);
    function feeRecipient() external view returns (address);
    function feeBps() external view returns (uint16);
    function STABLE() external view returns (address);
    function ROUTER() external view returns (address);
    function REGISTRY() external view returns (address);
}

/// @title EquityTreasury
/// @notice An AI-rebalanced basket of REAL tokenized equities on Robinhood
/// Chain. Holds stable (USDG) + equity-token legs at target weights; the
/// rebalancer retargets and executes swap steps through Uniswap v4 (the forked
/// UniversalRouter); valuation marks legs at CHAINLINK feed prices via
/// {EquityRegistry}. All swaps are atomic — there is no async-settlement state.
///
/// This is the EQUITY sibling of {StockTreasury}. It mirrors that contract's
/// structure, storage discipline, and {AgentCurve} integration EXACTLY — the
/// two differences are:
///   1. Valuation: Chainlink (equity feeds), not Uniswap v3 TWAP (memecoins).
///   2. Execution: Uniswap v4 via a forked UniversalRouter, not v3 SwapRouter02.
///
/// Baskets are HOMOGENEOUS: an equity treasury only ever holds equity legs
/// (v4/Chainlink). Memecoin legs live in {StockTreasury} (v3/TWAP). The two are
/// never mixed in one treasury.
///
/// Storage layout discipline:
///   - State variables below MUST be append-only across upgrades. Drop a slot
///     from `__gap` each time a new variable is added; never reorder, rename
///     types, or insert in the middle.
contract EquityTreasury is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0-equity-v4";

    uint16 private constant BPS_DENOM = 10000;

    uint16 public constant MAX_ASSETS = 20;

    /// Canonical Permit2 (AllowanceTransfer). VERIFIED as the exact `permit2`
    /// the forked UniversalRouter was constructed with (router constructor arg
    /// word 0) and to have code on Robinhood Chain. The router pulls swap inputs
    /// through this contract, so the treasury funds swaps via Permit2, never by
    /// approving the router directly.
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// Seconds past the swap deadline that a per-swap Permit2 allowance stays
    /// valid. Kept short — the allowance is set to the exact amountIn and fully
    /// consumed by the same-transaction swap; this is just slack for the router.
    uint48 private constant PERMIT2_EXPIRATION_BUFFER = 300;

    // ─── Storage ──────────────────────────────────────────────────────────
    // Slot order is the upgrade contract — DO NOT reorder. Append only.

    /// The forked UniversalRouter (Uniswap v4 execution venue).
    IUniversalRouterForked public ROUTER;

    IEquityRegistry public REGISTRY;

    IERC20 public STABLE;
    address public CREATOR;

    /// address allowed to set targets and execute rebalance steps.
    address public rebalancer;

    /// Pending rebalancer awaiting acceptance via acceptRebalancer
    address public pendingRebalancer;

    /// AgentCurve address
    address public curve;

    /// Tracked stock symbols. Read length via `assetCount()`.
    string[] public symbols;
    /// Asset config keyed by symbol. Public getter returns (token, targetBps, registered).
    mapping(string => AssetConfig) public assets;

    uint16 public minBps;

    /// Deploying factory, read for the global pause flag. Zero on a treasury
    /// deployed without a factory → pausing is simply unavailable.
    address public TREASURY_FACTORY;

    /// Idle stable from deposits
    uint256 public depositIdleStable;

    /// Padding to absorb future variable additions without shifting existing
    /// slots across beacon upgrades. Decrement when appending new storage.
    uint256[48] private __gap;

    struct AssetSpec {
        string symbol;
        address token;
        uint16 bps;
    }

    struct CurveInitParams {
        string name;
        string symbol;
        uint256 premiumCapSupply;
        uint256 extraPremium;
        uint256 stableSeed;
        address seeder;
        address recipient;
        uint256[] minTokenOuts;
    }

    event Deployed(uint256 stableIn, uint256 navAfter);
    event DeployDeferred(uint256 idle, uint256 threshold);
    event Withdrew(
        address indexed recipient,
        uint256 agentShares,
        uint256 totalShares,
        uint256 stableOut,
        uint256 navAfter
    );
    event RebalanceTargetSet(AssetSpec[] portfolio, string reasoningCid);
    event RebalanceStep(uint256 navAfter, uint256 idleStableAfter);
    event RebalancerProposed(address indexed current, address indexed proposed);
    event RebalancerChanged(address indexed previous, address indexed next);
    event TokenSold(string indexed symbol, address indexed token, uint256 tokenIn, uint256 stableOut);
    event BuySkippedPaused(string indexed symbol, uint256 stableAmount);
    event BuySkippedBelowMin(string indexed symbol, uint256 stableAmount, uint256 minTradeStable);
    event SellSkippedPaused(string indexed symbol, uint256 tokenAmount);
    event SellSkippedBelowMin(string indexed symbol, uint256 expectedStableOut, uint256 minTradeStable);
    event CurveSet(address indexed curve);
    event DustSwept(string indexed symbol, address indexed token, uint256 amount);
    /// A rebalance leg was skipped because its feed is fresh but pre-trade spot
    /// diverged beyond the band (we never trade into a manipulated pool).
    event RebalanceLegSkippedDiverged(string indexed symbol, address indexed token);

    error NotRebalancer();
    error NotPendingRebalancer();
    error NotCurve();
    error WeightsDoNotSumTo10000();
    error UnknownSymbol(string symbol);
    error ZeroAmount();
    error LengthMismatch();
    error InvalidAddress();
    error NoShares();
    error SlippageExceeded();
    error SymbolTokenMismatch(string symbol, address expected, address actual);
    error DuplicateSymbol(string symbol);
    error DuplicateToken(address token);
    error Paused();
    error InvalidReasoningCid();
    error TokenNotAllowed(address token);
    error TooManyAssets(uint256 given, uint256 max);
    error SymbolStillActive(string symbol);
    error SymbolStillSwappable(string symbol);
    error AmountTooLarge();
    /// A Chainlink-dependent flow (mint / rebalance / NAV) was attempted while at
    /// least one leg's feed is stale (weekend / holiday / after-hours). Issuance
    /// pauses; execution-priced redeem stays available.
    error MarketClosed(address token);
    /// Pre-trade spot diverged from a fresh Chainlink mark beyond the registry's
    /// `maxDivergenceBps` band — a manipulated or broken pool.
    error Diverged(address token);

    event MintPausedMarketClosed(address indexed token);
    event RedeemLegInKind(string indexed symbol, address indexed token, uint256 amount, bool stale, bool diverged);

    modifier onlyCurve() {
        if (msg.sender != curve) revert NotCurve();
        _;
    }

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer) revert NotRebalancer();
        _;
    }

    modifier whenNotPaused() {
        if (IEquityTreasuryFactory(TREASURY_FACTORY).paused()) revert Paused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice called by the BeaconProxy constructor. Signature MATCHES
    /// {StockTreasury.initialize} so the same factory/curve tooling applies.
    // slither-disable-next-line reentrancy-benign
    function initialize(
        address rebalancer_,
        address creator_,
        address treasuryFactory_,
        AssetSpec[] memory initialPortfolio,
        string memory initialReasoningCid,
        CurveInitParams memory curveInit
    ) external initializer nonReentrant {
        if (rebalancer_ == address(0) || creator_ == address(0) || treasuryFactory_ == address(0)) {
            revert InvalidAddress();
        }
        if (curveInit.seeder == address(0) || curveInit.recipient == address(0)) revert InvalidAddress();
        if (curveInit.stableSeed == 0) revert ZeroAmount();
        if (bytes(initialReasoningCid).length == 0) revert InvalidReasoningCid();

        IEquityTreasuryFactory f = IEquityTreasuryFactory(treasuryFactory_);
        TREASURY_FACTORY = treasuryFactory_;
        STABLE = IERC20(f.STABLE());
        rebalancer = rebalancer_;
        CREATOR = creator_;
        ROUTER = IUniversalRouterForked(f.ROUTER());
        REGISTRY = IEquityRegistry(f.REGISTRY());

        _setTargetPortfolio(initialPortfolio, initialReasoningCid);

        if (curveInit.minTokenOuts.length != symbols.length) revert LengthMismatch();

        // slither-disable-next-line arbitrary-send-erc20
        STABLE.safeTransferFrom(curveInit.seeder, address(this), curveInit.stableSeed);
        depositIdleStable = STABLE.balanceOf(address(this));
        _deployIdle(curveInit.minTokenOuts);

        AgentCurve spawned = new AgentCurve(
            curveInit.name,
            curveInit.symbol,
            address(this),
            address(STABLE),
            curveInit.premiumCapSupply,
            curveInit.extraPremium,
            curveInit.stableSeed,
            curveInit.seeder,
            curveInit.recipient
        );
        curve = address(spawned);
        emit CurveSet(address(spawned));
    }

    function deployUsdc(uint256 stableAmount, uint256[] calldata minTokenOuts)
        external
        onlyCurve
        nonReentrant
        whenNotPaused
    {
        if (stableAmount == 0) revert ZeroAmount();
        if (minTokenOuts.length != symbols.length) revert LengthMismatch();

        STABLE.safeTransferFrom(msg.sender, address(this), stableAmount);
        depositIdleStable += stableAmount;
        _deployIdle(minTokenOuts);
    }

    function _deployIdle(uint256[] memory minTokenOuts) internal {
        uint256 deployable = depositIdleStable;
        uint256 threshold = minDeployStable();
        if (deployable < threshold) {
            emit DeployDeferred(deployable, threshold);
            return;
        }
        uint256 spent = _buyTokens(deployable, minTokenOuts);
        depositIdleStable -= spent;
    }

    // slither-disable-next-line incorrect-equality,calls-loop,reentrancy-events
    function _buyTokens(uint256 stableAmount, uint256[] memory minTokenOuts) internal returns (uint256 spent) {
        uint256 n = symbols.length;

        uint256 deployed = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory sym = symbols[i];
            address token = assets[sym].token;

            uint256 stableToAllocate;
            if (i == n - 1 && assets[sym].targetBps != 0) {
                stableToAllocate = stableAmount - deployed;
            } else {
                stableToAllocate = (stableAmount * uint256(assets[sym].targetBps)) / BPS_DENOM;
                deployed += stableToAllocate;
            }

            if (stableToAllocate == 0) {
                if (minTokenOuts[i] != 0) revert SlippageExceeded();
                continue;
            }
            if (_isTransferPaused(token)) {
                if (minTokenOuts[i] != 0) revert SlippageExceeded();
                emit BuySkippedPaused(sym, stableToAllocate);
                continue;
            }

            uint256 minTrade = REGISTRY.minTradeStable();
            if (stableToAllocate < minTrade) {
                if (minTokenOuts[i] != 0) revert SlippageExceeded();
                emit BuySkippedBelowMin(sym, stableToAllocate, minTrade);
                continue;
            }

            // MINT is Chainlink-anchored: a leg being bought MUST have a fresh
            // feed (pauses issuance on weekends/holidays), and pre-trade spot
            // must be within the divergence band of that mark (guards a
            // manipulated / broken pool from handing the minter too many tokens).
            // Redeem, by contrast, never runs this gate — it is execution-priced.
            if (!REGISTRY.isFeedFresh(token)) revert MarketClosed(token);
            if (!REGISTRY.divergenceOk(token)) revert Diverged(token);

            _swapStableForToken(token, stableToAllocate, minTokenOuts[i]);
            spent += stableToAllocate;
        }

        emit Deployed(spent, nav());
    }

    function minDeployStable() public view returns (uint256) {
        if (minBps == 0) return type(uint256).max;
        uint256 minTrade = REGISTRY.minTradeStable();
        return (minTrade * BPS_DENOM + uint256(minBps) - 1) / uint256(minBps);
    }

    /// @notice EXECUTION-PRICED redeem — always available, including weekends.
    /// @dev No NAV/oracle mark enters the payout. The redeemer's pro-rata slice
    /// of EACH leg (`frac = agentShares / totalShares` of the live balance) is
    /// sold into its own USDG pool via the v4 path; the payout is the SUMMED
    /// REALIZED USDG (balance deltas) plus the pro-rata idle. Chainlink/spot are
    /// used ONLY to size each leg's `amountOutMinimum` floor, never the payout —
    /// so inflating a pool's spot before redeeming just makes the treasury sell
    /// into that impact (the manipulator bought high); there is no way to make
    /// the basket over-pay. Per-leg fallbacks keep one thin/stale/diverged leg
    /// from bricking the exit: it is handed over IN-KIND (when `returnTokens`).
    ///
    /// Floor per leg:
    ///   - feed FRESH  → require spot within the divergence band (else in-kind),
    ///                   floor = chainlink × (1 − slipBufferBps);
    ///   - feed STALE  → floor = spot × (1 − slipBufferStaleBps) [wider];
    ///   a manipulated spot only LOOSENS the floor, and realized proceeds are
    ///   still whatever the pool gives, so it cannot be gamed to over-pay.
    // slither-disable-next-line incorrect-equality,calls-loop,reentrancy-events,reentrancy-benign,reentrancy-no-eth
    function withdrawLtsTo(
        address recipient,
        uint256 agentShares,
        uint256 totalShares,
        uint256 minStableOut,
        bool returnTokens
    ) external onlyCurve nonReentrant whenNotPaused {
        if (agentShares == 0) revert ZeroAmount();
        if (totalShares == 0) revert NoShares();
        if (recipient == address(0)) revert InvalidAddress();

        uint256 n = symbols.length;

        // Pro-rata idle stable (no mark needed — USDG is the unit of account).
        uint256 idle = STABLE.balanceOf(address(this));
        uint256 idlePaid = (idle * agentShares) / totalShares;
        if (idlePaid > 0) _consumeStable(idlePaid, idle);

        uint256 realized = 0;
        bool anyInKind = false;
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 sellAmt = (IERC20(token).balanceOf(address(this)) * agentShares) / totalShares;
            if (sellAmt == 0) continue;

            (bool doSwap, uint256 floor, bool stale, bool diverged) = _redeemLegPlan(token, sellAmt);
            if (doSwap) {
                // slither-disable-next-line calls-loop,reentrancy-events
                (bool ok, uint256 got) = _trySellTokenForStable(token, sellAmt, floor);
                if (ok) {
                    realized += got;
                    continue;
                }
            }
            // In-kind fallback: paused / stale / diverged / thin leg, or a swap
            // that breached its floor. Redeem never blocks on one leg.
            if (returnTokens) {
                anyInKind = true;
                uint256 tokenFee = (sellAmt * feeBps()) / BPS_DENOM;
                if (tokenFee > 0) IERC20(token).safeTransfer(feeRecipient(), tokenFee);
                IERC20(token).safeTransfer(recipient, sellAmt - tokenFee);
                emit RedeemLegInKind(symbols[i], token, sellAmt, stale, diverged);
            }
        }

        uint256 stableOut = idlePaid + realized;
        uint256 fee = (stableOut * feeBps()) / BPS_DENOM;
        uint256 netOut = stableOut - fee;

        // Global realized-USDG floor on the amount actually received. Relaxed
        // when any leg went in-kind: the stable portion is legitimately partial
        // then, and the redeemer holds the underlying they can trade themselves.
        if (netOut < minStableOut && !anyInKind) revert SlippageExceeded();

        if (fee > 0) STABLE.safeTransfer(feeRecipient(), fee);
        if (netOut > 0) STABLE.safeTransfer(recipient, netOut);

        // navAfter is 0: no oracle mark is taken on the redeem path (it may be
        // MarketClosed), and the payout is realized, not marked.
        emit Withdrew(recipient, agentShares, totalShares, netOut, 0);
    }

    /// @dev Decide how to settle one redeem leg. Returns whether to swap, the
    /// per-leg `amountOutMinimum` floor, and (`stale`,`diverged`) for events.
    /// A paused token, a fresh-but-diverged pool, or (implicitly, via a zero
    /// floor that the realized check still bounds) a dead pool routes to in-kind.
    function _redeemLegPlan(address token, uint256 sellAmt)
        internal
        view
        returns (bool doSwap, uint256 floor, bool stale, bool diverged)
    {
        if (_isTransferPaused(token)) return (false, 0, false, false);

        if (REGISTRY.isFeedFresh(token)) {
            // Fresh: never trade into a manipulated/broken pool.
            if (!REGISTRY.divergenceOk(token)) return (false, 0, false, true);
            uint256 expected = REGISTRY.valueOf(token, sellAmt);
            floor = (expected * (BPS_DENOM - REGISTRY.slipBufferBps())) / BPS_DENOM;
            return (true, floor, false, false);
        }

        // Stale: size the floor off (manipulable) spot with a WIDER buffer. Spot
        // only loosens the floor; realized proceeds are still whatever the pool
        // pays, so this cannot be gamed to over-pay.
        uint256 spotExpected = REGISTRY.spotValueOf(token, sellAmt);
        floor = (spotExpected * (BPS_DENOM - REGISTRY.slipBufferStaleBps())) / BPS_DENOM;
        return (true, floor, true, false);
    }

    function setTargetPortfolio(AssetSpec[] calldata newPortfolio, string calldata reasoningCid)
        external
        onlyRebalancer
        nonReentrant
    {
        if (bytes(reasoningCid).length == 0) revert InvalidReasoningCid();
        _setTargetPortfolio(newPortfolio, reasoningCid);
    }

    /// @notice One swap pass toward the target weights. Runs 24/7 — INCLUDING
    /// weekends/holidays when Chainlink is stale — and is a DISTINCT path from
    /// mint (`AgentCurve.buy` → `nav()` → `MarketClosed`), which stays gated. See
    /// docs/EQUITY_REBALANCE_ANYTIME.md.
    ///
    /// @dev Uses STALENESS-TOLERANT sizing (`_markValue`/`_markAmount`/
    /// `_rebalanceNav`): Chainlink when the leg's feed is fresh AND the sequencer
    /// is up, else the v4 pool's manipulable spot. It therefore NEVER calls the
    /// reverting `nav()`/`valueOf` and NEVER reverts `MarketClosed`. Every leg
    /// swap keeps a realized `amountOutMinimum` floor = max(caller floor,
    /// expected × (1 − buffer)), buffer = `slipBufferBps` when priced off fresh
    /// Chainlink else the wider `slipBufferStaleBps`. Safety rests on two
    /// properties, not on the sizing mark: (1) authorized-rebalancer-only (an
    /// external actor cannot trigger it against a manipulated spot), and (2) the
    /// per-swap floor bounds worst-case execution regardless of that mark. When
    /// the feed is fresh the divergence guard additionally skips a leg whose spot
    /// is outside the band; when stale there is nothing to compare, so it's
    /// floor-only.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events,reentrancy-balance,incorrect-equality,calls-loop
    function executeRebalanceStep(
        uint256[] calldata maxSellToken,
        uint256[] calldata minSellStable,
        uint256[] calldata maxBuyStable,
        uint256[] calldata minBuyToken
    ) external onlyRebalancer nonReentrant {
        uint256 n = symbols.length;
        if (maxSellToken.length != n || minSellStable.length != n || maxBuyStable.length != n || minBuyToken.length != n) {
            revert LengthMismatch();
        }

        uint256 navAtStart = _rebalanceNav();

        // sell loop
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance == 0) continue;

            // Never trade a fresh-but-diverged leg into a manipulated pool.
            if (REGISTRY.isFeedFresh(token) && !REGISTRY.divergenceOk(token)) {
                emit RebalanceLegSkippedDiverged(symbols[i], token);
                continue;
            }

            uint256 currentStableValue = _markValue(token, tokenBalance);
            uint256 targetStableValue = (navAtStart * uint256(assets[symbols[i]].targetBps)) / BPS_DENOM;
            if (targetStableValue >= currentStableValue) continue;

            uint256 shrinkToken;
            if (assets[symbols[i]].targetBps == 0) {
                shrinkToken = tokenBalance;
            } else {
                uint256 shrinkStable = currentStableValue - targetStableValue;
                shrinkToken = _markAmount(token, shrinkStable);
                if (shrinkToken == 0) continue;
                if (shrinkToken > tokenBalance) shrinkToken = tokenBalance;
            }
            if (shrinkToken > maxSellToken[i]) shrinkToken = maxSellToken[i];
            if (shrinkToken == 0) {
                if (minSellStable[i] != 0) revert SlippageExceeded();
                continue;
            }

            if (_isTransferPaused(token)) {
                if (minSellStable[i] != 0) revert SlippageExceeded();
                emit SellSkippedPaused(symbols[i], shrinkToken);
                continue;
            }

            uint256 expectedStableOut = _markValue(token, shrinkToken);
            uint256 minTrade = REGISTRY.minTradeStable();
            if (expectedStableOut < minTrade) {
                if (minSellStable[i] != 0) revert SlippageExceeded();
                emit SellSkippedBelowMin(symbols[i], expectedStableOut, minTrade);
                continue;
            }

            uint256 floorStable = _sellFloor(token, expectedStableOut, minSellStable[i]);
            uint256 stableOut = _swapTokenForStable(token, shrinkToken, floorStable);
            emit TokenSold(symbols[i], token, shrinkToken, stableOut);
        }

        uint256 navForBuys = _rebalanceNav();

        // buy loop
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;

            if (REGISTRY.isFeedFresh(token) && !REGISTRY.divergenceOk(token)) {
                emit RebalanceLegSkippedDiverged(symbols[i], token);
                continue;
            }

            uint256 currentStableValue = _markValue(token, IERC20(token).balanceOf(address(this)));
            uint256 targetStableValue = (navForBuys * uint256(assets[symbols[i]].targetBps)) / BPS_DENOM;
            if (targetStableValue <= currentStableValue) continue;

            uint256 growStable = targetStableValue - currentStableValue;
            if (growStable > maxBuyStable[i]) growStable = maxBuyStable[i];
            if (growStable == 0) continue;

            uint256 stableBal = STABLE.balanceOf(address(this));
            if (growStable > stableBal) {
                if (stableBal == 0) continue;
                growStable = stableBal;
            }

            if (_isTransferPaused(token)) {
                emit BuySkippedPaused(symbols[i], growStable);
                continue;
            }

            uint256 minTrade = REGISTRY.minTradeStable();
            if (growStable < minTrade) {
                if (minBuyToken[i] != 0) revert SlippageExceeded();
                emit BuySkippedBelowMin(symbols[i], growStable, minTrade);
                continue;
            }

            uint256 floorToken = _buyFloor(token, growStable, minBuyToken[i]);
            _consumeStable(growStable, stableBal);
            _swapStableForToken(token, growStable, floorToken);
        }

        _pruneExitedSymbols();

        emit RebalanceStep(_rebalanceNav(), STABLE.balanceOf(address(this)));
    }

    // ── Staleness-tolerant sizing (rebalance only) ──────────────────────────
    //
    // Rebalance must run 24/7, so it must NOT touch the reverting nav()/valueOf.
    // These mark a leg at Chainlink when its feed is fresh (sequencer up), else
    // at the v4 pool's (manipulable) spot. Never used for mint or the redeem
    // PAYOUT — only rebalance weight sizing + floor sizing, where the per-swap
    // realized floor + authorized-only access are the actual safety backstops.

    function _rebalanceNav() internal view returns (uint256 total) {
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) total += _markValue(token, bal);
        }
        total += STABLE.balanceOf(address(this));
    }

    /// @dev Stable value of `tokenAmt`: Chainlink if fresh, else spot.
    function _markValue(address token, uint256 tokenAmt) internal view returns (uint256) {
        if (REGISTRY.isFeedFresh(token)) return REGISTRY.valueOf(token, tokenAmt);
        return REGISTRY.spotValueOf(token, tokenAmt);
    }

    /// @dev Token amount worth `stableValue`: Chainlink inverse if fresh, else a
    /// spot inverse (assumes 18-dec equity tokens — the only class here).
    function _markAmount(address token, uint256 stableValue) internal view returns (uint256) {
        if (REGISTRY.isFeedFresh(token)) return REGISTRY.amountOf(token, stableValue);
        uint256 unitValue = REGISTRY.spotValueOf(token, 1e18); // USDG per 1e18 token
        if (unitValue == 0) return 0;
        return (stableValue * 1e18) / unitValue;
    }

    /// @dev SELL floor (stable out): max(caller floor, expected × (1 − buffer)),
    /// buffer wider when priced off spot.
    function _sellFloor(address token, uint256 expectedStableOut, uint256 callerFloor)
        internal
        view
        returns (uint256)
    {
        uint16 buffer = REGISTRY.isFeedFresh(token) ? REGISTRY.slipBufferBps() : REGISTRY.slipBufferStaleBps();
        uint256 bufFloor = (expectedStableOut * (BPS_DENOM - buffer)) / BPS_DENOM;
        return callerFloor > bufFloor ? callerFloor : bufFloor;
    }

    /// @dev BUY floor (token out): max(caller floor, expected × (1 − buffer)).
    function _buyFloor(address token, uint256 growStable, uint256 callerFloor) internal view returns (uint256) {
        uint256 expectedToken = _markAmount(token, growStable);
        uint16 buffer = REGISTRY.isFeedFresh(token) ? REGISTRY.slipBufferBps() : REGISTRY.slipBufferStaleBps();
        uint256 bufFloor = (expectedToken * (BPS_DENOM - buffer)) / BPS_DENOM;
        return callerFloor > bufFloor ? callerFloor : bufFloor;
    }

    function feeRecipient() public view returns (address) {
        return IEquityTreasuryFactory(TREASURY_FACTORY).feeRecipient();
    }

    function feeBps() public view returns (uint16) {
        return IEquityTreasuryFactory(TREASURY_FACTORY).feeBps();
    }

    // ─── Swap plumbing (Uniswap v4, forked UniversalRouter + Permit2) ───────
    //
    // Equity pools are DIRECT USDG↔token v4 pools (single hop). Unlike v3's
    // SwapRouter02 (which returns amountOut), the UniversalRouter's execute()
    // returns nothing, so realized output is measured as a balance delta. Input
    // is pulled by the router through Permit2 (see PERMIT2), so funding is a
    // two-leg approve: token→Permit2 (ERC-20, one-time max) then Permit2→router
    // (per-swap, exact amount).

    /// @dev BUY: STABLE → token, exact-in.
    function _swapStableForToken(address token, uint256 stableIn, uint256 minTokenOut)
        internal
        returns (uint256 tokenOut)
    {
        tokenOut = _v4ExactInput(token, stableIn, minTokenOut, true);
    }

    /// @dev SELL: token → STABLE, exact-in.
    function _swapTokenForStable(address token, uint256 tokenIn, uint256 minStableOut)
        internal
        returns (uint256 stableOut)
    {
        stableOut = _v4ExactInput(token, tokenIn, minStableOut, false);
    }

    /// @dev Non-reverting SELL used inside the withdraw deficit loop, so one
    /// bad leg (paused token, dead pool, router revert) can't brick the whole
    /// exit. Mirrors the try/catch around `SWAP_ROUTER.exactInput` in
    /// {StockTreasury.withdrawLtsTo}. Uses an external self-call because a
    /// try/catch cannot wrap an internal call; on revert the whole sub-frame
    /// (incl. the Permit2 approvals) rolls back, so no cleanup is needed.
    function _trySellTokenForStable(address token, uint256 tokenIn, uint256 minOut)
        internal
        returns (bool ok, uint256 stableOut)
    {
        // slither-disable-next-line reentrancy-events
        try this.swapTokenForStableSelf(token, tokenIn, minOut) returns (uint256 got) {
            ok = true;
            stableOut = got;
        } catch {
            // sub-frame reverted and rolled back (floor breach, dead pool, …) —
            // leave state untouched; the caller settles this leg in-kind.
        }
    }

    /// @dev External-but-self-only shim so the withdraw loop can try/catch a
    /// swap. `minOut` is the per-leg execution floor computed by `_redeemLegPlan`
    /// — a breach reverts `SlippageExceeded` inside `_v4ExactInput`, which the
    /// try/catch turns into an in-kind settlement.
    function swapTokenForStableSelf(address token, uint256 tokenIn, uint256 minOut)
        external
        returns (uint256 stableOut)
    {
        if (msg.sender != address(this)) revert NotCurve();
        stableOut = _v4ExactInput(token, tokenIn, minOut, false);
    }

    /// @dev Core single-hop v4 exact-input swap through the forked router.
    /// @param equityToken the non-stable leg (identifies the direct USDG↔token pool).
    /// @param amountIn    exact input amount.
    /// @param minOut      slippage floor on measured output.
    /// @param isBuy       true → spending STABLE for `equityToken`; false →
    ///                    spending `equityToken` for STABLE.
    ///
    /// Calldata is hand-encoded for the fork by {V4SwapEncoder} (verified ABI:
    /// the swap params carry a Robinhood `minHopPriceX36` field, passed 0 to
    /// disable the router's per-hop floor since we enforce our own realized
    /// floor below). Funding is Permit2, not a direct router approve.
    function _v4ExactInput(address equityToken, uint256 amountIn, uint256 minOut, bool isBuy)
        internal
        returns (uint256 out)
    {
        (address tokenIn, address tokenOut) =
            isBuy ? (address(STABLE), equityToken) : (equityToken, address(STABLE));
        uint128 amtIn = _u128(amountIn);

        V4PoolKey.PoolKey memory key = REGISTRY.poolKey(equityToken);
        bool zeroForOne = tokenIn == key.currency0;

        // Permit2 funding: one-time max token→Permit2 ERC-20 allowance, then a
        // per-swap Permit2→router allowance sized to exactly this input.
        _ensurePermit2Erc20Allowance(tokenIn, amtIn);
        IPermit2(PERMIT2).approve(
            tokenIn, address(ROUTER), amtIn, uint48(block.timestamp) + PERMIT2_EXPIRATION_BUFFER
        );

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        (bytes memory commands, bytes[] memory inputs) =
            V4SwapEncoder.encodeExactInSingle(key, zeroForOne, tokenIn, tokenOut, amtIn, _u128(minOut), 0);
        // slither-disable-next-line reentrancy-events
        ROUTER.execute(commands, inputs, block.timestamp);

        out = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (out < minOut) revert SlippageExceeded();
    }

    /// @dev Ensure the token grants Permit2 a sufficient ERC-20 allowance. Set
    /// once to max (Permit2 is the canonical, audited allowance hub) and reused
    /// across swaps; re-approved only if it ever drops below what's needed.
    function _ensurePermit2Erc20Allowance(address token, uint256 amountIn) internal {
        if (IERC20(token).allowance(address(this), PERMIT2) < amountIn) {
            IERC20(token).forceApprove(PERMIT2, type(uint256).max);
        }
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert AmountTooLarge();
        return uint128(x);
    }

    /// Issuer pause probe, tolerant of plain ERC-20s without `paused()`.
    function _isTransferPaused(address token) internal view returns (bool) {
        try IStockToken(token).paused() returns (bool p) {
            return p;
        } catch {
            return false;
        }
    }

    function _pruneExitedSymbols() internal {
        uint256 i = 0;
        while (i < symbols.length) {
            string memory sym = symbols[i];
            AssetConfig storage a = assets[sym];
            // slither-disable-next-line incorrect-equality,calls-loop
            if (a.targetBps == 0 && IERC20(a.token).balanceOf(address(this)) == 0) {
                uint256 last = symbols.length - 1;
                if (i != last) symbols[i] = symbols[last];
                symbols.pop();
                delete assets[sym];
            } else {
                i++;
            }
        }
    }

    /// @notice Forcibly remove a retired symbol whose residual balance can no
    /// longer be drained through a swap, sending that residual to CREATOR.
    /// Restricted to `targetBps == 0`. Same rationale as {StockTreasury.sweepDust}.
    function sweepDust(string calldata symbol) external onlyRebalancer nonReentrant {
        AssetConfig storage a = assets[symbol];
        if (!a.registered) revert UnknownSymbol(symbol);
        if (a.targetBps != 0) revert SymbolStillActive(symbol);

        address token = a.token;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (REGISTRY.tokenExists(token)) {
            if (REGISTRY.valueOf(token, bal) >= REGISTRY.minTradeStable()) revert SymbolStillSwappable(symbol);
        }
        if (bal > 0) IERC20(token).safeTransfer(CREATOR, bal);

        _removeSymbol(symbol);
        delete assets[symbol];
        emit DustSwept(symbol, token, bal);
    }

    /// Swap-pop `symbol` out of `symbols[]`. Caller deletes `assets[symbol]`.
    function _removeSymbol(string memory symbol) internal {
        uint256 n = symbols.length;
        bytes32 target = keccak256(bytes(symbol));
        for (uint256 i = 0; i < n; i++) {
            if (keccak256(bytes(symbols[i])) == target) {
                uint256 last = n - 1;
                if (i != last) symbols[i] = symbols[last];
                symbols.pop();
                return;
            }
        }
    }

    /// Update depositIdleStable after spending stable, treating non-deposit idle as spent first.
    function _consumeStable(uint256 amount, uint256 balanceBefore) internal {
        uint256 depositIdle = depositIdleStable;
        if (depositIdle == 0 || amount == 0) return;

        uint256 swapProceeds = balanceBefore > depositIdle ? balanceBefore - depositIdle : 0;
        if (amount <= swapProceeds) return;

        uint256 fromDeposits = amount - swapProceeds;
        depositIdleStable = fromDeposits >= depositIdle ? 0 : depositIdle - fromDeposits;
    }

    function proposeRebalancer(address next) external onlyRebalancer {
        if (next == address(0)) revert InvalidAddress();
        pendingRebalancer = next;
        emit RebalancerProposed(rebalancer, next);
    }

    function acceptRebalancer() external {
        if (msg.sender != pendingRebalancer) revert NotPendingRebalancer();
        emit RebalancerChanged(rebalancer, msg.sender);
        rebalancer = msg.sender;
        pendingRebalancer = address(0);
    }

    /// @notice Sum of all equity tokens held (at Chainlink marks) + idle stable.
    /// @dev DISPLAY / MINT valuation ONLY — it MUST NOT be used to price a
    /// redeem (redeem is execution-priced; see {withdrawLtsTo}). Reverts
    /// `MarketClosed` if any held leg's feed is stale, which is the mechanism
    /// that pauses mint (AgentCurve.buy reads nav()) and rebalance
    /// (executeRebalanceStep sizes off nav()) on weekends/holidays while the
    /// underlying keeps trading and redeem stays open.
    function nav() public view returns (uint256) {
        _requireMarketOpen();
        return EquityTreasuryValuation.nav(symbols, assets, STABLE, REGISTRY);
    }

    /// @dev Gate the Chainlink-dependent path (mint / rebalance / NAV). Reverts
    /// `SequencerDown` / `SequencerGracePeriod` on an L2 outage (surfaced
    /// DISTINCTLY so the agent/UI can tell an outage from a weekend), then
    /// `MarketClosed` if any HELD leg's feed is stale. Non-held (zero-balance)
    /// legs don't gate — they contribute nothing to the valuation and shouldn't
    /// block issuance for the rest of the basket. Redeem never calls this.
    function _requireMarketOpen() internal view {
        REGISTRY.requireSequencerUp();
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            address t = assets[symbols[i]].token;
            if (IERC20(t).balanceOf(address(this)) > 0 && !REGISTRY.isFeedFresh(t)) {
                revert MarketClosed(t);
            }
        }
    }

    function quoteWithdrawUsdc(uint256 agentShares, uint256 totalShares) public view returns (uint256) {
        return EquityTreasuryValuation.quoteWithdrawStable(
            symbols, assets, STABLE, REGISTRY, agentShares, totalShares, feeBps()
        );
    }

    function assetCount() external view returns (uint256) {
        return symbols.length;
    }

    function _setTargetPortfolio(AssetSpec[] memory newPortfolio, string memory reasoningCid) internal {
        if (newPortfolio.length > MAX_ASSETS) revert TooManyAssets(newPortfolio.length, MAX_ASSETS);

        uint256 sum = 0;
        uint16 smallest = type(uint16).max;
        for (uint256 i = 0; i < newPortfolio.length; i++) {
            sum += newPortfolio[i].bps;
            if (newPortfolio[i].bps > 0 && newPortfolio[i].bps < smallest) {
                smallest = newPortfolio[i].bps;
            }
        }
        if (sum != 10000) revert WeightsDoNotSumTo10000();

        uint256 existingN = symbols.length;
        for (uint256 i = 0; i < existingN; i++) {
            assets[symbols[i]].targetBps = 0;
        }

        for (uint256 i = 0; i < newPortfolio.length; i++) {
            AssetSpec memory spec = newPortfolio[i];
            if (spec.token == address(0)) revert InvalidAddress();
            for (uint256 j = 0; j < i; j++) {
                if (keccak256(bytes(spec.symbol)) == keccak256(bytes(newPortfolio[j].symbol))) {
                    revert DuplicateSymbol(spec.symbol);
                }
                if (spec.token == newPortfolio[j].token) revert DuplicateToken(spec.token);
            }

            AssetConfig storage asset = assets[spec.symbol];
            if (!asset.registered) {
                if (!REGISTRY.tokenExists(spec.token)) revert TokenNotAllowed(spec.token);

                uint256 nSyms = symbols.length;
                for (uint256 k = 0; k < nSyms; k++) {
                    if (assets[symbols[k]].token == spec.token) revert DuplicateToken(spec.token);
                }

                symbols.push(spec.symbol);
                assets[spec.symbol] = AssetConfig({token: spec.token, targetBps: spec.bps, registered: true});
            } else if (asset.token != spec.token) {
                revert SymbolTokenMismatch(spec.symbol, asset.token, spec.token);
            } else {
                asset.targetBps = spec.bps;
            }
        }

        if (symbols.length > MAX_ASSETS) revert TooManyAssets(symbols.length, MAX_ASSETS);

        minBps = (smallest == type(uint16).max) ? 0 : smallest;

        emit RebalanceTargetSet(newPortfolio, reasoningCid);
    }
}
