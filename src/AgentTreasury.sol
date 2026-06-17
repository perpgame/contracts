// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IBounceGlobalStorage, IBounceLT} from "./interfaces/IBounceLT.sol";
import {AgentCurve} from "./AgentCurve.sol";
import {TreasuryValuation, AssetConfig} from "./TreasuryValuation.sol";

/// atomic-redeem capacity per LT
interface ILeveragedTokenHelper {
    function getLeveragedTokenBufferAssetValue(address lt) external view returns (int256);
}

interface IBounceFactory {
    function lts() external view returns (address[] memory);
    function ltExists(address lt) external view returns (bool);
    function globalStorage() external view returns (address);
}

interface ITreasuryFactory {
    function paused() external view returns (bool);
    function feeRecipient() external view returns (address);
    function feeBps() external view returns (uint16);
    function USDC() external view returns (address);
    function LT_HELPER() external view returns (address);
    function BOUNCE_FACTORY() external view returns (address);
}

/// Storage layout discipline:
///   - State variables below MUST be append-only across upgrades. Drop a slot
///     from `__gap` each time a new variable is added; never reorder, rename
///     types, or insert in the middle.
contract AgentTreasury is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "2.1.0-upgradeable";

    uint16 private constant BPS_DENOM = 10000;

    uint16 public constant MAX_ASSETS = 20;

    // ─── Storage ──────────────────────────────────────────────────────────
    // Slot order is the upgrade contract — DO NOT reorder. Append only.

    /// Bounce's helper
    ILeveragedTokenHelper public LT_HELPER;

    IBounceFactory public BOUNCE_FACTORY;

    IERC20 public USDC;
    address public CREATOR;

    /// address allowed to set targets and execute rebalance steps.
    address public rebalancer;

    /// Pending rebalancer awaiting acceptance via acceptRebalancer
    address public pendingRebalancer;

    /// AgentCurve address
    address public curve;

    /// Tracked LT symbols. Read length via `assetCount()`.
    string[] public symbols;
    /// Asset config keyed by symbol. Public getter returns (lt, targetBps, registered).
    mapping(string => AssetConfig) public assets;

    bool public rebalanceInFlight;

    uint16 public minBps;

    /// Deploying TreasuryFactory, read for the global pause flag. Zero on a
    /// treasury deployed without a factory → pausing is simply unavailable.
    address public TREASURY_FACTORY;

    /// Idle USDC from deposits
    uint256 public depositIdleUsdc;

    /// Padding to absorb future variable additions without shifting existing
    /// slots across beacon upgrades. Decrement when appending new storage.
    uint256[48] private __gap;

    // AssetConfig lives in TreasuryValuation.sol so the library and this
    // contract share one definition (the storage layout for `assets`).

    struct AssetSpec {
        string symbol;
        address lt;
        uint16 bps;
    }

    struct CurveInitParams {
        string name;
        string symbol;
        uint256 premiumCapSupply;
        uint256 extraPremium;
        uint256 usdcSeed;
        address seeder;
        address recipient;
        uint256[] minLtOuts;
    }

    event Deployed(uint256 usdcIn, uint256 navAfter);
    event DeployDeferred(uint256 idle, uint256 threshold);
    event Withdrew(
        address indexed recipient,
        uint256 agentShares,
        uint256 totalShares,
        uint256 usdcOut,
        uint256 navAfter
    );
    event RebalanceTargetSet(AssetSpec[] portfolio, string reasoningCid);
    event RebalanceStep(uint256 navAfter, uint256 idleUsdcAfter);
    event RebalanceInFlightChanged(bool inFlight);
    event RebalancerProposed(address indexed current, address indexed proposed);
    event RebalancerChanged(address indexed previous, address indexed next);
    event RedemptionPrepared(string indexed symbol, address indexed lt, uint256 ltAmount, uint256 expectedBaseAmount);
    event AtomicRedeem(string indexed symbol, address indexed lt, uint256 ltAmount, uint256 baseAmount);
    event MintDeferredForSettlement(string indexed symbol, uint256 usdcRequired, uint256 usdcAvailable);
    event MintSkippedPaused(string indexed symbol, uint256 usdcAmount);
    event MintSkippedBelowMin(string indexed symbol, uint256 usdcAmount, uint256 minTransactionSize);
    event RedeemSkippedBelowMin(string indexed symbol, uint256 expectedBaseOut, uint256 minTransactionSize);
    event CurveSet(address indexed curve);
    event DustSwept(string indexed symbol, address indexed lt, uint256 amount);
    event LtMigrated(string indexed symbol, address indexed oldLt, address indexed newLt, uint256 movedBalance);

    error NotRebalancer();
    error NotPendingRebalancer();
    error NotCurve();
    error WeightsDoNotSumTo10000();
    error UnknownSymbol(string symbol);
    error ZeroAmount();
    error SymbolAlreadyRegistered(string symbol);
    error LengthMismatch();
    error InvalidAddress();
    error NoShares();
    error SlippageExceeded();
    error SymbolTokenMismatch(string symbol, address expected, address actual);
    error DuplicateSymbol(string symbol);
    error DuplicateLt(address lt);
    error RebalancePending();
    error Paused();
    error InsufficientUsdcForMint(string symbol, uint256 required, uint256 available);
    error InvalidReasoningCid();
    error LtNotAllowed(address lt);
    error TooManyAssets(uint256 given, uint256 max);
    error SymbolStillActive(string symbol);
    error SymbolStillRedeemable(string symbol);
    error RedeemPending(string symbol);

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
        if (curveInit.usdcSeed == 0) revert ZeroAmount();
        if (bytes(initialReasoningCid).length == 0) revert InvalidReasoningCid();

        ITreasuryFactory f = ITreasuryFactory(treasuryFactory_);
        TREASURY_FACTORY = treasuryFactory_;
        USDC = IERC20(f.USDC());
        rebalancer = rebalancer_;
        CREATOR = creator_;
        LT_HELPER = ILeveragedTokenHelper(f.LT_HELPER());
        BOUNCE_FACTORY = IBounceFactory(f.BOUNCE_FACTORY());

        _setTargetPortfolio(initialPortfolio, initialReasoningCid);

        if (curveInit.minLtOuts.length != symbols.length) revert LengthMismatch();

        // slither-disable-next-line arbitrary-send-erc20
        USDC.safeTransferFrom(curveInit.seeder, address(this), curveInit.usdcSeed);
        depositIdleUsdc = USDC.balanceOf(address(this));
        _deployIdle(curveInit.minLtOuts);

        AgentCurve spawned = new AgentCurve(
            curveInit.name,
            curveInit.symbol,
            address(this),
            address(USDC),
            curveInit.premiumCapSupply,
            curveInit.extraPremium,
            curveInit.usdcSeed,
            curveInit.seeder,
            curveInit.recipient
        );
        curve = address(spawned);
        emit CurveSet(address(spawned));
    }

    function deployUsdc(uint256 usdcAmount, uint256[] calldata minLtOuts) external onlyCurve nonReentrant whenNotPaused {
        if (usdcAmount == 0) revert ZeroAmount();
        if (minLtOuts.length != symbols.length) revert LengthMismatch();
        if (rebalanceInFlight) revert RebalancePending();

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        depositIdleUsdc += usdcAmount;
        _deployIdle(minLtOuts);
    }

    function _deployIdle(uint256[] memory minLtOuts) internal {
        uint256 deployable = depositIdleUsdc;
        uint256 threshold = minDeployUsdc();
        if (deployable < threshold) {
            emit DeployDeferred(deployable, threshold);
            return;
        }
        uint256 spent = _mintLTs(deployable, minLtOuts);
        depositIdleUsdc -= spent;
    }

    // slither-disable-next-line incorrect-equality,calls-loop,reentrancy-events
    function _mintLTs(uint256 usdcAmount, uint256[] memory minLtOuts) internal returns (uint256 spent) {
        uint256 n = symbols.length;

        uint256 deployed = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory sym = symbols[i];
            IBounceLT lt = IBounceLT(assets[sym].lt);

            uint256 usdcToAllocate;
            // The last leg absorbs the flooring remainder — but only if it's an
            // active (bps != 0) leg. A zeroed leg lingering in symbols[] at the
            // last slot must be treated like any other zeroed leg (allocate 0,
            // skipped below); otherwise it receives a few wei of dust and
            // lt.mint reverts BelowMinTransactionSize, bricking the whole deploy.
            // The unrouted remainder simply stays idle.
            if (i == n - 1 && assets[sym].targetBps != 0) {
                usdcToAllocate = usdcAmount - deployed;
            } else {
                usdcToAllocate = (usdcAmount * uint256(assets[sym].targetBps)) / BPS_DENOM;
                deployed += usdcToAllocate;
            }

            if (usdcToAllocate == 0) {
                if (minLtOuts[i] != 0) revert SlippageExceeded();
                continue;
            }
            // A paused LT must not brick the whole buy/deploy. Skip its mint and
            // leave this leg's USDC idle — it stays in nav() at face value and
            // deploys on a later buy/rebalance once unpaused. `deployed` already
            // counts this leg's share, so the final leg's remainder is unaffected
            // and no value is lost (idle USDC fully backs the minted shares).
            if (lt.mintPaused()) {
                // A caller demanding exposure to this leg (minLtOuts[i] != 0)
                // must not be silently fobbed off with idle USDC — honor the
                // floor as the usdcToAllocate == 0 branch above does. Callers
                // passing minLtOuts[i] == 0 keep the skip-paused resilience.
                if (minLtOuts[i] != 0) revert SlippageExceeded();
                emit MintSkippedPaused(sym, usdcToAllocate);
                continue;
            }

            uint256 minTxSize = _minTransactionSize();
            if (usdcToAllocate < minTxSize) {
                if (minLtOuts[i] != 0) revert SlippageExceeded();
                emit MintSkippedBelowMin(sym, usdcToAllocate, minTxSize);
                continue;
            }

            USDC.forceApprove(address(lt), usdcToAllocate);
            uint256 ltOut = lt.mint(address(this), usdcToAllocate, minLtOuts[i]);
            if (ltOut < minLtOuts[i]) revert SlippageExceeded();
            spent += usdcToAllocate;
        }

        emit Deployed(spent, nav());
    }

    function minDeployUsdc() public view returns (uint256) {
        if (minBps == 0) return type(uint256).max;
        uint256 minTransactionSize = _minTransactionSize();
        return (minTransactionSize * BPS_DENOM + uint256(minBps) - 1) / uint256(minBps);
    }

    // slither-disable-next-line incorrect-equality,calls-loop,reentrancy-events,reentrancy-benign,reentrancy-no-eth
    function withdrawLtsTo(
        address recipient,
        uint256 agentShares,
        uint256 totalShares,
        uint256 minUsdcOut,
        bool returnLts
    ) external onlyCurve nonReentrant whenNotPaused {
        if (agentShares == 0) revert ZeroAmount();
        if (totalShares == 0) revert NoShares();
        if (recipient == address(0)) revert InvalidAddress();
        if (rebalanceInFlight) revert RebalancePending();

        uint256 n = symbols.length;

        uint256 idle = USDC.balanceOf(address(this));

        (uint256[] memory ltValues, uint256 totalLtValue) = _heldLtValues();

        uint256 navTotal = idle + totalLtValue;
        uint256 notional = (navTotal * agentShares) / totalShares;

        if (notional < minUsdcOut) revert SlippageExceeded();

        // 1. Pay the seller their PRO-RATA slice of idle USDC — not idle-first.
        //    Paying idle-first lets a seller whose notional fits in idle exit
        //    entirely in cash at the (un-checkpointed, stale-high) LT mark and
        //    leave their LT slice behind; the pending streaming fee on that slice
        //    then falls on remaining holders. Pro-rata makes `remaining` equal
        //    exactly the seller's LT-value slice, so they always carry their own
        //    LT (and its fee) out via the deficit loop below.
        uint256 idlePaid = (idle * agentShares) / totalShares;
        if (idlePaid > 0) _consumeUsdc(idlePaid, idle);

        // 2. Cover the deficit per leg: try to redeem the seller's pro-rata slice
        //    to USDC instantly. If Bounce can't fill it now (instant-redeem buffer
        //    too low, below min size, paused, …) the redeem reverts and we catch
        //    it. With `returnLts` set we hand the seller that leg's raw LT to
        //    convert later (frontend / Bounce async redeem). With `returnLts`
        //    false the seller wants USDC only, so we simply skip the leg — its LT
        //    stays in the treasury and the seller is paid only what redeemed.
        //    Redeemed USDC is forwarded once after the loop.
        uint256 remaining = notional - idlePaid;
        uint256 redeemed = 0;
        if (remaining > 0) {
            for (uint256 i = 0; i < n; i++) {
                if (ltValues[i] == 0) continue;
                IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
                uint256 bal = lt.balanceOf(address(this));
                uint256 ltOut = (bal * remaining) / totalLtValue;
                if (ltOut == 0) continue;
                // slither-disable-next-line calls-loop,reentrancy-events
                try lt.redeem(address(this), ltOut, 0) returns (uint256 got) {
                    redeemed += got;
                } catch {
                    if (returnLts) {
                        uint256 ltFee = (ltOut * feeBps()) / BPS_DENOM;
                        if (ltFee > 0) IERC20(address(lt)).safeTransfer(feeRecipient(), ltFee);
                        IERC20(address(lt)).safeTransfer(recipient, ltOut - ltFee);
                    }
                }
            }
        }
        uint256 usdcOut = idlePaid + redeemed;
        uint256 fee = (usdcOut * feeBps()) / BPS_DENOM;
        uint256 netOut = usdcOut - fee;

        if (!returnLts && netOut < minUsdcOut) revert SlippageExceeded();

        if (fee > 0) USDC.safeTransfer(feeRecipient(), fee);
        if (netOut > 0) USDC.safeTransfer(recipient, netOut);

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

    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events,reentrancy-balance,incorrect-equality,calls-loop
    function executeRebalanceStep(
        uint256[] calldata maxRedeemLt,
        uint256[] calldata minRedeemUsdc,
        uint256[] calldata maxMintUsdc,
        uint256[] calldata minMintLt
    ) external onlyRebalancer nonReentrant {

        uint256 n = symbols.length;
        if (maxRedeemLt.length != n || minRedeemUsdc.length != n || maxMintUsdc.length != n || minMintLt.length != n) {
            revert LengthMismatch();
        }

        uint256 navAtStart = nav();

        // sell loop
        for (uint256 i = 0; i < n; i++) {
            IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
            uint256 ltBalance = lt.balanceOf(address(this));
            if (ltBalance == 0) continue;

            uint256 currentUsdcValue = lt.ltToBaseAmount(ltBalance);
            uint256 targetUsdcValue = (navAtStart * uint256(assets[symbols[i]].targetBps)) / BPS_DENOM;
            if (targetUsdcValue >= currentUsdcValue) continue;

            uint256 shrinkLt;
            if (assets[symbols[i]].targetBps == 0) {
                shrinkLt = ltBalance;
            } else {
                uint256 shrinkUsdc = currentUsdcValue - targetUsdcValue;
                shrinkLt = lt.baseToLtAmount(shrinkUsdc);
                if (shrinkLt == 0) continue;
                if (shrinkLt > ltBalance) shrinkLt = ltBalance;
            }
            if (shrinkLt > maxRedeemLt[i]) shrinkLt = maxRedeemLt[i];
            if (shrinkLt == 0) {
                if (minRedeemUsdc[i] != 0) revert SlippageExceeded();
                continue;
            }

            uint256 expectedBaseOut = lt.ltToBaseAmount(shrinkLt);
            uint256 minTxSize = _minTransactionSize();
            if (expectedBaseOut < minTxSize) {
                if (minRedeemUsdc[i] != 0) revert SlippageExceeded();
                emit RedeemSkippedBelowMin(symbols[i], expectedBaseOut, minTxSize);
                continue;
            }

            // If LT has enough USDC in buffer, use atomic redeem(), else async path.
            if (_redeemFitsBuffer(lt, expectedBaseOut)) {
                uint256 actualBaseOut = lt.redeem(address(this), shrinkLt, minRedeemUsdc[i]);
                emit AtomicRedeem(symbols[i], address(lt), shrinkLt, actualBaseOut);
            } else {
                if (!rebalanceInFlight) {
                    rebalanceInFlight = true;
                    emit RebalanceInFlightChanged(true);
                }
                lt.prepareRedeem(shrinkLt);
                emit RedemptionPrepared(symbols[i], address(lt), shrinkLt, expectedBaseOut);
            }
        }

        // Re-measure nav after the sell loop. Redeems paid fees and checkpointed
        // the LTs (streaming fee), lowering true nav and exchange rates; sizing
        // buy targets off the pre-sell `navAtStart` would over-allocate. Counts
        // in-flight escrowed redemptions so idle USDC still deploys correctly.
        uint256 navForBuys = _navWithPendingRedemptions();

        // buy loop
        for (uint256 i = 0; i < n; i++) {
            IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
            uint256 currentUsdcValue = lt.ltToBaseAmount(lt.balanceOf(address(this)));
            uint256 targetUsdcValue = (navForBuys * uint256(assets[symbols[i]].targetBps)) / BPS_DENOM;
            if (targetUsdcValue <= currentUsdcValue) continue;

            uint256 growUsdc = targetUsdcValue - currentUsdcValue;
            if (growUsdc > maxMintUsdc[i]) growUsdc = maxMintUsdc[i];
            if (growUsdc == 0) continue;

            uint256 usdcBal = USDC.balanceOf(address(this));
            if (growUsdc > usdcBal) {
                if (rebalanceInFlight) {
                    emit MintDeferredForSettlement(symbols[i], growUsdc, usdcBal);
                    continue;
                }
                // `growUsdc` is sized from gross navAtStart, but a same-step sell
                // delivers proceeds NET of Bounce's redemption fee, so on the
                // atomic path the shortfall is exactly that fee. Mint what the
                // proceeds actually cover rather than reverting the whole step;
                // the residual (off-target by the fee) settles on a later step.
                if (usdcBal == 0) continue;
                growUsdc = usdcBal;
            }

            // Skip a paused leg rather than reverting the whole step — its grow
            // USDC stays idle and the next pass (or a later step once unpaused)
            // completes the mint. Mirrors the settlement-defer continue above.
            if (lt.mintPaused()) {
                emit MintSkippedPaused(symbols[i], growUsdc);
                continue;
            }

            uint256 minTxSize = _minTransactionSize();
            if (growUsdc < minTxSize) {
                if (minMintLt[i] != 0) revert SlippageExceeded();
                emit MintSkippedBelowMin(symbols[i], growUsdc, minTxSize);
                continue;
            }

            USDC.forceApprove(address(lt), growUsdc);
            _consumeUsdc(growUsdc, usdcBal);
            uint256 ltOut = lt.mint(address(this), growUsdc, minMintLt[i]);
            if (ltOut < minMintLt[i]) revert SlippageExceeded();
        }

        // If bounce.tech owes us no USDC, finish rebalance.
        // Assumes grow loop above has consumed any settled USDC.
        _clearInFlightIfSettled();

        _pruneExitedSymbols();

        emit RebalanceStep(nav(), USDC.balanceOf(address(this)));
    }

    function settleRebalance() external {
        _clearInFlightIfSettled();
    }

    function _minTransactionSize() internal view returns (uint256) {
        return IBounceGlobalStorage(BOUNCE_FACTORY.globalStorage()).minTransactionSize();
    }

    function feeRecipient() public view returns (address) {
        return ITreasuryFactory(TREASURY_FACTORY).feeRecipient();
    }

    function feeBps() public view returns (uint16) {
        return ITreasuryFactory(TREASURY_FACTORY).feeBps();
    }

    /// Recover from a pending async redemption that Bounce can no longer settle.
    /// `_executeRedemption` returns early without clearing `userCredit` when the
    /// credit's base value falls below the flat executor fee (a depreciated leg),
    /// so the leg's `userCredit` — and thus the basket-wide `rebalanceInFlight`
    /// flag — would otherwise stay set forever, freezing all buys and sells.
    /// `cancelRedeem` (callable after Bounce's cancel delay) pulls the escrowed
    /// LT back into the treasury and zeroes the credit; we then re-check whether
    /// the flag can clear.
    function cancelRedeem(string calldata symbol) external onlyRebalancer nonReentrant {
        AssetConfig storage a = assets[symbol];
        if (!a.registered) revert UnknownSymbol(symbol);
        IBounceLT(a.lt).cancelRedeem();
        _clearInFlightIfSettled();
    }

    function _pruneExitedSymbols() internal {
        uint256 i = 0;
        while (i < symbols.length) {
            string memory sym = symbols[i];
            AssetConfig storage a = assets[sym];
            IBounceLT lt = IBounceLT(a.lt);
            // slither-disable-next-line incorrect-equality,calls-loop
            if (
                a.targetBps == 0 && lt.balanceOf(address(this)) == 0
                    && lt.userCredit(address(this)) == 0
            ) {
                uint256 last = symbols.length - 1;
                if (i != last) symbols[i] = symbols[last];
                symbols.pop();
                delete assets[sym];
            } else {
                i++;
            }
        }
    }

    /// @notice Forcibly remove a retired symbol whose residual LT balance can no
    /// longer be drained through Bounce, sending that residual to CREATOR.
    /// @dev The only removal path otherwise is `_pruneExitedSymbols`, which needs
    /// `balanceOf == 0`. Bounce LTs are ordinary ERC-20s, so anyone can send 1 wei
    /// of a retired LT to keep `balanceOf != 0` forever (and a 1-wei leg has
    /// `ltToBaseAmount == 0`, so the redeem loops skip it) — pinning the symbol in
    /// `symbols[]` permanently and taxing every NAV/deploy/rebalance iteration plus
    /// every caller's slippage-array length. This lets the rebalancer evict such a
    /// leg. Restricted to `targetBps == 0` so an active position can never be swept.
    /// Requires the leg's async credit to be settled first so no owed USDC is
    /// abandoned. For true dust the swept value is ~0; for a stranded delisted-LT
    /// position this hands CREATOR the tokens to redeem off-protocol, which lowers
    /// NAV by that leg's value — an intentional, rebalancer-gated recovery.
    function sweepDust(string calldata symbol) external onlyRebalancer nonReentrant {
        AssetConfig storage a = assets[symbol];
        if (!a.registered) revert UnknownSymbol(symbol);
        if (a.targetBps != 0) revert SymbolStillActive(symbol);

        IBounceLT lt = IBounceLT(a.lt);
        if (lt.userCredit(address(this)) != 0) revert RedeemPending(symbol);

        uint256 bal = lt.balanceOf(address(this));
        if (BOUNCE_FACTORY.ltExists(address(lt))) {
            if (lt.ltToBaseAmount(bal) >= _minTransactionSize()) revert SymbolStillRedeemable(symbol);
        }
        if (bal > 0) IERC20(address(lt)).safeTransfer(CREATOR, bal);

        _removeSymbol(symbol);
        delete assets[symbol];
        emit DustSwept(symbol, address(lt), bal);
    }

    /// @notice Re-point a registered symbol at a new LT contract for the same
    /// product, e.g. after Bounce's `Factory::redeployLt` swaps an LT's address
    /// while preserving its deterministic symbol.
    /// @dev `_setTargetPortfolio` reverts `SymbolTokenMismatch` on any LT change, so
    /// without this a redeploy orphans the entry: its `lt` is the delisted contract,
    /// which the treasury can no longer drain, so the prune condition can never be
    /// met and the freed symbol cannot be re-registered. The new LT must be a current
    /// factory LT and unused by another symbol. Any stranded balance on the old
    /// (delisted) LT is handed to CREATOR before re-pointing, since `nav()` would
    /// otherwise stop counting it the moment `lt` changes; a pending async credit on
    /// the old LT must be settled first so its USDC is not abandoned.
    function migrateLt(string calldata symbol, address newLt) external onlyRebalancer nonReentrant {
        if (newLt == address(0)) revert InvalidAddress();
        AssetConfig storage a = assets[symbol];
        if (!a.registered) revert UnknownSymbol(symbol);

        address oldLt = a.lt;
        if (oldLt == newLt) revert SymbolTokenMismatch(symbol, oldLt, newLt);

        // O(1) factory membership check (see setTargetPortfolio) — avoids
        // copying & scanning the unbounded BOUNCE_FACTORY.lts() array.
        if (!BOUNCE_FACTORY.ltExists(newLt)) revert LtNotAllowed(newLt);

        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            if (assets[symbols[i]].lt == newLt) revert DuplicateLt(newLt);
        }

        if (IBounceLT(oldLt).userCredit(address(this)) != 0) revert RedeemPending(symbol);
        uint256 oldBal = IBounceLT(oldLt).balanceOf(address(this));
        if (oldBal > 0) IERC20(oldLt).safeTransfer(CREATOR, oldBal);

        a.lt = newLt;
        emit LtMigrated(symbol, oldLt, newLt, oldBal);
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

    // slither-disable-next-line calls-loop
    function _clearInFlightIfSettled() internal {
        if (!rebalanceInFlight) return;

        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            if (IBounceLT(assets[symbols[i]].lt).userCredit(address(this)) > 0) {
                return; // still pending — leave the flag set
            }
        }

        rebalanceInFlight = false;
        emit RebalanceInFlightChanged(false);
    }

    /// Update depositIdleUsdc after spending USDC, treating non-deposit idle as spent first.
    function _consumeUsdc(uint256 amount, uint256 balanceBefore) internal {
        uint256 depositIdle = depositIdleUsdc;
        if (depositIdle == 0 || amount == 0) return;

        uint256 redemptionProceeds = balanceBefore > depositIdle ? balanceBefore - depositIdle : 0;
        if (amount <= redemptionProceeds) return;

        uint256 fromDeposits = amount - redemptionProceeds;
        depositIdleUsdc = fromDeposits >= depositIdle ? 0 : depositIdle - fromDeposits;
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

    function _heldLtValues() internal view returns (uint256[] memory ltValues, uint256 totalLtValue) {
        return TreasuryValuation.heldLtValues(symbols, assets);
    }

    function _redeemFitsBuffer(IBounceLT lt, uint256 expectedBase) internal view returns (bool) {
        return TreasuryValuation.redeemFitsBuffer(address(LT_HELPER), lt, expectedBase);
    }

    /// Sum of all LTs held + idle USDC
    function nav() public view returns (uint256) {
        return TreasuryValuation.nav(symbols, assets, USDC);
    }

    function quoteWithdrawUsdc(uint256 agentShares, uint256 totalShares) public view returns (uint256) {
        return TreasuryValuation.quoteWithdrawUsdc(
            symbols, assets, USDC, address(LT_HELPER), agentShares, totalShares, _minTransactionSize(), feeBps()
        );
    }

    /// nav() plus the value of in-flight (escrowed) redemptions. `prepareRedeem`
    /// moves LT into Bounce's escrow — out of `balanceOf` — while recording
    /// `userCredit`, so plain nav() omits that still-owned value. Used to size
    /// buy targets after the sell loop: redeems pay fees and checkpoint the LTs
    /// (lowering true nav and rates), so targets must be measured against the
    /// post-sell value while still counting redemptions that haven't settled.
    function _navWithPendingRedemptions() internal view returns (uint256) {
        return TreasuryValuation.navWithPendingRedemptions(symbols, assets, USDC);
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
            if (spec.lt == address(0)) revert InvalidAddress();
            for (uint256 j = 0; j < i; j++) {
                if (keccak256(bytes(spec.symbol)) == keccak256(bytes(newPortfolio[j].symbol))) {
                    revert DuplicateSymbol(spec.symbol);
                }
                if (spec.lt == newPortfolio[j].lt) revert DuplicateLt(spec.lt);
            }

            AssetConfig storage asset = assets[spec.symbol];
            if (!asset.registered) {
                // O(1) factory membership check — avoids copying & scanning the
                // whole BOUNCE_FACTORY.lts() array, which grows unbounded as
                // Bounce's catalog expands and would otherwise cap this path.
                if (!BOUNCE_FACTORY.ltExists(spec.lt)) revert LtNotAllowed(spec.lt);

                uint256 nSyms = symbols.length;
                for (uint256 k = 0; k < nSyms; k++) {
                    if (assets[symbols[k]].lt == spec.lt) revert DuplicateLt(spec.lt);
                }

                symbols.push(spec.symbol);
                assets[spec.symbol] = AssetConfig({lt: spec.lt, targetBps: spec.bps, registered: true});
            } else if (asset.lt != spec.lt) {
                revert SymbolTokenMismatch(spec.symbol, asset.lt, spec.lt);
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
