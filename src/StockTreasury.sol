// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IStockTokenRegistry} from "./interfaces/IStockTokenRegistry.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {AgentCurve} from "./AgentCurve.sol";
import {StockTreasuryValuation, AssetConfig} from "./StockTreasuryValuation.sol";

interface ITreasuryFactory {
    function paused() external view returns (bool);
    function feeRecipient() external view returns (address);
    function feeBps() external view returns (uint16);
    function STABLE() external view returns (address);
    function SWAP_ROUTER() external view returns (address);
    function REGISTRY() external view returns (address);
}

/// An AI-rebalanced basket of Robinhood Chain stock tokens. Holds stable
/// (USDG) + stock-token legs at target weights; the rebalancer retargets and
/// executes swap steps through Uniswap v3; valuation marks legs at Chainlink
/// feed prices via the StockTokenRegistry. All swaps are atomic — there is no
/// async-settlement state, unlike the Bounce-LT ancestor of this contract.
///
/// Storage layout discipline:
///   - State variables below MUST be append-only across upgrades. Drop a slot
///     from `__gap` each time a new variable is added; never reorder, rename
///     types, or insert in the middle.
contract StockTreasury is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0-stock";

    uint16 private constant BPS_DENOM = 10000;

    uint16 public constant MAX_ASSETS = 20;

    // ─── Storage ──────────────────────────────────────────────────────────
    // Slot order is the upgrade contract — DO NOT reorder. Append only.

    ISwapRouter02 public SWAP_ROUTER;

    IStockTokenRegistry public REGISTRY;

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

    /// Deploying TreasuryFactory, read for the global pause flag. Zero on a
    /// treasury deployed without a factory → pausing is simply unavailable.
    address public TREASURY_FACTORY;

    /// Idle stable from deposits
    uint256 public depositIdleStable;

    /// Padding to absorb future variable additions without shifting existing
    /// slots across beacon upgrades. Decrement when appending new storage.
    uint256[48] private __gap;

    // AssetConfig lives in StockTreasuryValuation.sol so the library and this
    // contract share one definition (the storage layout for `assets`).

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

    modifier onlyCurve() {
        if (msg.sender != curve) revert NotCurve();
        _;
    }

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer) revert NotRebalancer();
        _;
    }

    modifier whenNotPaused() {
        if (ITreasuryFactory(TREASURY_FACTORY).paused()) revert Paused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// The implementation contract itself must never be initialized (only the proxy's storage is meant to be initialized).
    constructor() {
        _disableInitializers();
    }

    /// @notice called by the BeaconProxy constructor
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

        ITreasuryFactory f = ITreasuryFactory(treasuryFactory_);
        TREASURY_FACTORY = treasuryFactory_;
        STABLE = IERC20(f.STABLE());
        rebalancer = rebalancer_;
        CREATOR = creator_;
        SWAP_ROUTER = ISwapRouter02(f.SWAP_ROUTER());
        REGISTRY = IStockTokenRegistry(f.REGISTRY());

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
            // The last leg absorbs the flooring remainder — but only if it's an
            // active (bps != 0) leg. A zeroed leg lingering in symbols[] at the
            // last slot must be treated like any other zeroed leg (allocate 0,
            // skipped below); otherwise it receives a few wei of dust that a
            // pool swap can't fill, bricking the whole deploy. The unrouted
            // remainder simply stays idle.
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
            // A paused stock token must not brick the whole buy/deploy. Skip
            // its swap and leave this leg's stable idle — it stays in nav() at
            // face value and deploys on a later buy/rebalance once unpaused.
            // `deployed` already counts this leg's share, so the final leg's
            // remainder is unaffected and no value is lost (idle stable fully
            // backs the minted shares).
            if (_isTransferPaused(token)) {
                // A caller demanding exposure to this leg (minTokenOuts[i] != 0)
                // must not be silently fobbed off with idle stable — honor the
                // floor as the stableToAllocate == 0 branch above does. Callers
                // passing minTokenOuts[i] == 0 keep the skip-paused resilience.
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

        uint256 idle = STABLE.balanceOf(address(this));

        // Tolerant per-leg valuation. A leg whose oracle mark reverts (stale or
        // invalid feed — a weekend/holiday/corporate-action freeze) must NOT
        // brick the whole exit; the strict library valuation used by nav() does
        // exactly that, so exits can't route through it (audit HIGH-3). Here we
        // catch the revert, mark the leg unpriceable, and settle it in-kind
        // below so a holder can always redeem their pro-rata assets, oracle or
        // not. Priceable legs and the total exclude unpriceable ones.
        uint256[] memory tokenValues = new uint256[](n);
        bool[] memory priced = new bool[](n);
        uint256 totalTokenValue = 0;
        for (uint256 i = 0; i < n; i++) {
            address t = assets[symbols[i]].token;
            uint256 b = IERC20(t).balanceOf(address(this));
            if (b == 0) {
                priced[i] = true; // nothing to value/settle
                continue;
            }
            // slither-disable-next-line calls-loop
            try REGISTRY.valueOf(t, b) returns (uint256 v) {
                tokenValues[i] = v;
                totalTokenValue += v;
                priced[i] = true;
            } catch {
                // leave priced[i] == false → settled in-kind below
            }
        }

        uint256 navTotal = idle + totalTokenValue;
        uint256 notional = (navTotal * agentShares) / totalShares;

        if (notional < minStableOut) revert SlippageExceeded();

        // 1. Pay the seller their PRO-RATA slice of idle stable — not idle-first.
        //    Paying idle-first lets a seller whose notional fits in idle exit
        //    entirely in cash at the oracle mark and leave their token slice
        //    behind; the swap costs (pool fee + impact) on that slice then fall
        //    on remaining holders. Pro-rata makes `remaining` equal exactly the
        //    seller's token-value slice, so they always carry their own legs
        //    (and their exit costs) out via the deficit loop below.
        uint256 idlePaid = (idle * agentShares) / totalShares;
        if (idlePaid > 0) _consumeStable(idlePaid, idle);

        // 2. Cover the deficit per leg. Priceable legs: swap the seller's
        //    pro-rata slice to stable on Uniswap; on swap failure (token paused,
        //    pool gone, …) we catch and, with `returnTokens`, hand over the raw
        //    tokens (else skip — stable-only sellers leave the leg behind).
        //    Unpriceable legs: no swap is possible without a mark, so with
        //    `returnTokens` we hand the seller their pure pro-rata raw slice
        //    (oracle-free); stable-only sellers skip the leg. `anyInKind` records
        //    whether any raw tokens were handed out, which relaxes the realized-
        //    stable floor below.
        uint256 remaining = notional - idlePaid;
        uint256 swapped = 0;
        bool anyInKind = false;
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;

            if (!priced[i]) {
                if (!returnTokens) continue;
                uint256 rawSlice = (IERC20(token).balanceOf(address(this)) * agentShares) / totalShares;
                if (rawSlice == 0) continue;
                anyInKind = true;
                uint256 rawFee = (rawSlice * feeBps()) / BPS_DENOM;
                if (rawFee > 0) IERC20(token).safeTransfer(feeRecipient(), rawFee);
                IERC20(token).safeTransfer(recipient, rawSlice - rawFee);
                continue;
            }

            if (tokenValues[i] == 0 || remaining == 0 || totalTokenValue == 0) continue;
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 tokenOut = (bal * remaining) / totalTokenValue;
            if (tokenOut == 0) continue;
            IERC20(token).forceApprove(address(SWAP_ROUTER), tokenOut);
            // slither-disable-next-line calls-loop,reentrancy-events
            try SWAP_ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: address(STABLE),
                    fee: REGISTRY.poolFee(token),
                    recipient: address(this),
                    amountIn: tokenOut,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 got) {
                swapped += got;
            } catch {
                IERC20(token).forceApprove(address(SWAP_ROUTER), 0);
                if (returnTokens) {
                    anyInKind = true;
                    uint256 tokenFee = (tokenOut * feeBps()) / BPS_DENOM;
                    if (tokenFee > 0) IERC20(token).safeTransfer(feeRecipient(), tokenFee);
                    IERC20(token).safeTransfer(recipient, tokenOut - tokenFee);
                }
            }
        }
        uint256 stableOut = idlePaid + swapped;
        uint256 fee = (stableOut * feeBps()) / BPS_DENOM;
        uint256 netOut = stableOut - fee;

        // Realized-stable slippage floor. The gross-notional check above is an
        // ORACLE mark; the swaps realize the LIVE pool price, so a sandwich can
        // clear the oracle check yet pay out far less. Enforce the floor on the
        // amount actually received (audit HIGH-1: previously gated on
        // !returnTokens, leaving returnTokens=true swaps unprotected). When any
        // leg was returned in-kind, the stable portion is legitimately below
        // minStableOut, so the oracle-notional floor above is the binding check
        // instead and this one is relaxed.
        if (netOut < minStableOut && !anyInKind) revert SlippageExceeded();

        if (fee > 0) STABLE.safeTransfer(feeRecipient(), fee);
        if (netOut > 0) STABLE.safeTransfer(recipient, netOut);

        emit Withdrew(recipient, agentShares, totalShares, netOut, navTotal - notional);
    }

    function setTargetPortfolio(AssetSpec[] calldata newPortfolio, string calldata reasoningCid)
        external
        onlyRebalancer
        nonReentrant
    {
        if (bytes(reasoningCid).length == 0) revert InvalidReasoningCid();
        _setTargetPortfolio(newPortfolio, reasoningCid);
    }

    /// One swap pass toward the target weights. Per leg the caller supplies
    /// caps and floors only — actual sizes are recomputed here from live
    /// balances and oracle marks: sells are capped by `maxSellToken` with a
    /// per-leg Uniswap floor `minSellStable`; buys are capped by
    /// `maxBuyStable` (and by stable on hand) with floor `minBuyToken`. Sell
    /// proceeds land in the same step's buy loop, so a full rebalance is
    /// usually a single step; residuals settle on later steps.
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

        uint256 navAtStart = nav();

        // sell loop
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance == 0) continue;

            uint256 currentStableValue = REGISTRY.valueOf(token, tokenBalance);
            uint256 targetStableValue = (navAtStart * uint256(assets[symbols[i]].targetBps)) / BPS_DENOM;
            if (targetStableValue >= currentStableValue) continue;

            uint256 shrinkToken;
            if (assets[symbols[i]].targetBps == 0) {
                shrinkToken = tokenBalance;
            } else {
                uint256 shrinkStable = currentStableValue - targetStableValue;
                shrinkToken = REGISTRY.amountOf(token, shrinkStable);
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

            uint256 expectedStableOut = REGISTRY.valueOf(token, shrinkToken);
            uint256 minTrade = REGISTRY.minTradeStable();
            if (expectedStableOut < minTrade) {
                if (minSellStable[i] != 0) revert SlippageExceeded();
                emit SellSkippedBelowMin(symbols[i], expectedStableOut, minTrade);
                continue;
            }

            uint256 stableOut = _swapTokenForStable(token, shrinkToken, minSellStable[i]);
            emit TokenSold(symbols[i], token, shrinkToken, stableOut);
        }

        // Re-measure nav after the sell loop. Sells realize pool fees and
        // price impact, lowering true nav; sizing buy targets off the pre-sell
        // `navAtStart` would over-allocate.
        uint256 navForBuys = nav();

        // buy loop
        for (uint256 i = 0; i < n; i++) {
            address token = assets[symbols[i]].token;
            uint256 currentStableValue = REGISTRY.valueOf(token, IERC20(token).balanceOf(address(this)));
            uint256 targetStableValue = (navForBuys * uint256(assets[symbols[i]].targetBps)) / BPS_DENOM;
            if (targetStableValue <= currentStableValue) continue;

            uint256 growStable = targetStableValue - currentStableValue;
            if (growStable > maxBuyStable[i]) growStable = maxBuyStable[i];
            if (growStable == 0) continue;

            uint256 stableBal = STABLE.balanceOf(address(this));
            if (growStable > stableBal) {
                // `growStable` is sized from pre-swap marks, but same-step sell
                // proceeds arrive NET of pool fees + impact, so the shortfall
                // is exactly those costs. Buy what the proceeds actually cover
                // rather than reverting the whole step; the residual settles
                // on a later step.
                if (stableBal == 0) continue;
                growStable = stableBal;
            }

            // Skip a paused leg rather than reverting the whole step — its grow
            // stable stays idle and a later step completes the buy once unpaused.
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

            _consumeStable(growStable, stableBal);
            _swapStableForToken(token, growStable, minBuyToken[i]);
        }

        _pruneExitedSymbols();

        emit RebalanceStep(nav(), STABLE.balanceOf(address(this)));
    }

    function feeRecipient() public view returns (address) {
        return ITreasuryFactory(TREASURY_FACTORY).feeRecipient();
    }

    function feeBps() public view returns (uint16) {
        return ITreasuryFactory(TREASURY_FACTORY).feeBps();
    }

    // ─── Swap plumbing ────────────────────────────────────────────────────

    function _swapStableForToken(address token, uint256 stableIn, uint256 minTokenOut)
        internal
        returns (uint256 tokenOut)
    {
        STABLE.forceApprove(address(SWAP_ROUTER), stableIn);
        tokenOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(STABLE),
                tokenOut: token,
                fee: REGISTRY.poolFee(token),
                recipient: address(this),
                amountIn: stableIn,
                amountOutMinimum: minTokenOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapTokenForStable(address token, uint256 tokenIn, uint256 minStableOut)
        internal
        returns (uint256 stableOut)
    {
        IERC20(token).forceApprove(address(SWAP_ROUTER), tokenIn);
        stableOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(STABLE),
                fee: REGISTRY.poolFee(token),
                recipient: address(this),
                amountIn: tokenIn,
                amountOutMinimum: minStableOut,
                sqrtPriceLimitX96: 0
            })
        );
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
    /// @dev The only removal path otherwise is `_pruneExitedSymbols`, which needs
    /// `balanceOf == 0`. Stock tokens are ordinary ERC-20s, so anyone can send
    /// 1 wei of a retired token to keep `balanceOf != 0` forever — pinning the
    /// symbol in `symbols[]` permanently and taxing every NAV/deploy/rebalance
    /// iteration plus every caller's slippage-array length. This lets the
    /// rebalancer evict such a leg. Restricted to `targetBps == 0` so an active
    /// position can never be swept. For true dust the swept value is ~0; for a
    /// stranded position (delisted token, dead pool) this hands CREATOR the
    /// tokens to liquidate off-protocol, which lowers NAV by that leg's value —
    /// an intentional, rebalancer-gated recovery.
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

    /// Sum of all stock tokens held (at Chainlink marks) + idle stable
    function nav() public view returns (uint256) {
        return StockTreasuryValuation.nav(symbols, assets, STABLE, REGISTRY);
    }

    function quoteWithdrawUsdc(uint256 agentShares, uint256 totalShares) public view returns (uint256) {
        return StockTreasuryValuation.quoteWithdrawStable(
            symbols, assets, STABLE, REGISTRY, agentShares, totalShares, feeBps()
        );
    }

    function assetCount() external view returns (uint256) {
        return symbols.length;
    }

    function _setTargetPortfolio(AssetSpec[] memory newPortfolio, string memory reasoningCid) internal {
        if (newPortfolio.length > MAX_ASSETS) revert TooManyAssets(newPortfolio.length, MAX_ASSETS);

        // Weights must sum to 100% (in bps).
        uint256 sum = 0;
        uint16 smallest = type(uint16).max;
        for (uint256 i = 0; i < newPortfolio.length; i++) {
            sum += newPortfolio[i].bps;
            if (newPortfolio[i].bps > 0 && newPortfolio[i].bps < smallest) {
                smallest = newPortfolio[i].bps;
            }
        }
        if (sum != 10000) revert WeightsDoNotSumTo10000();

        // Zero out all existing weights so anything not re-set ends up at bps=0.
        uint256 existingN = symbols.length;
        for (uint256 i = 0; i < existingN; i++) {
            assets[symbols[i]].targetBps = 0;
        }

        // Apply new weights and register new symbols.
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
                // O(1) registry membership check.
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

        // Enforce the cap against the LIVE array, not just `newPortfolio`: legs
        // dropped to bps=0 linger in `symbols[]` until pruned/swept, so checking
        // only the incoming length lets the stored set grow past MAX_ASSETS. If
        // this trips, prune (a rebalance step) or `sweepDust` retired legs first.
        if (symbols.length > MAX_ASSETS) revert TooManyAssets(symbols.length, MAX_ASSETS);

        minBps = (smallest == type(uint16).max) ? 0 : smallest;

        emit RebalanceTargetSet(newPortfolio, reasoningCid);
    }
}
