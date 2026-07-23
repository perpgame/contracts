// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EquityTreasury} from "../src/EquityTreasury.sol";
import {EquityRegistry} from "../src/EquityRegistry.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {V4PoolKey} from "../src/libraries/V4PoolKey.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockUniversalRouterForked} from "./mocks/MockUniversalRouterForked.sol";
import {MockEquityTreasuryFactory} from "./mocks/MockEquityTreasuryFactory.sol";
import {MockSequencerFeed} from "./mocks/MockSequencerFeed.sol";

/// End-to-end equity treasury tests exercising the CONFIRMED Uniswap v4 forked-
/// router path (Chainlink valuation + Permit2 funding + hand-encoded v4
/// calldata). The router mock decodes and asserts the exact wire format,
/// including `minHopPriceX36`'s position between amountOutMinimum and hookData.
///
/// Mirrors StockTreasury.t.sol / StockTreasuryNavFreeze.t.sol structure; the
/// equity-specific twist is that a stale Chainlink feed (the normal weekend /
/// after-hours state of a 24/5 equity feed) is the freeze/in-kind trigger,
/// not "insufficient TWAP history".
contract EquityTreasuryTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    MockUSDC usdg;
    MockStockToken tokenA; // AAPL
    MockStockToken tokenB; // TSLA
    MockAggregator feedA;
    MockAggregator feedB;
    MockStateView stateView;
    MockSequencerFeed seq;
    EquityRegistry registry;
    MockUniversalRouterForked router;
    MockEquityTreasuryFactory factory;
    EquityTreasury treasury;
    AgentCurve curve;
    uint32 constant HB = 86_400;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_000); // a fixed, non-trivial timestamp

        usdg = new MockUSDC();
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");
        feedA = new MockAggregator(8, 200e8); // $200
        feedB = new MockAggregator(8, 100e8); // $100
        stateView = new MockStateView();
        seq = new MockSequencerFeed(0, 1); // sequencer up, past grace

        registry = new EquityRegistry(address(this), address(usdg), address(stateView), address(seq));
        // Calibrate each pool's spot to its Chainlink mark ($200 / $100 per 1e18)
        // so the divergence guard has a sane baseline; the mock router prices at
        // the Chainlink mark regardless, so this only affects spot-derived floors
        // and the divergence band.
        _seedPoolAt(address(tokenA), 200e6);
        _seedPoolAt(address(tokenB), 100e6);
        registry.addToken(address(tokenA), address(feedA), FEE, TICK_SPACING, HB);
        registry.addToken(address(tokenB), address(feedB), FEE, TICK_SPACING, HB);
        registry.setMinTradeStable(1e6);

        // Put the mock Permit2 at the canonical address the treasury references.
        vm.etch(PERMIT2, address(new MockPermit2()).code);

        router = new MockUniversalRouterForked(PERMIT2, address(usdg), address(registry));
        usdg.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        factory = new MockEquityTreasuryFactory(address(usdg), address(router), address(registry));
        factory.setFeeBps(0); // exact NAV conservation in the base tests

        usdg.mint(alice, 1_000_000 * 1e6);
        usdg.mint(bob, 1_000_000 * 1e6);

        EquityTreasury impl = new EquityTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));

        EquityTreasury.CurveInitParams memory ci = EquityTreasury.CurveInitParams({
            name: "Equity Alpha",
            symbol: "EQA",
            premiumCapSupply: 30_000 * 1e18,
            extraPremium: 2e18,
            stableSeed: 1_000 * 1e6,
            seeder: alice,
            recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        bytes memory initData = abi.encodeCall(
            EquityTreasury.initialize,
            (rebalancer, creator, address(factory), _portfolio2(5000, 5000), "ipfs://genesis", ci)
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdg.approve(predicted, ci.stableSeed);
        treasury = EquityTreasury(address(new BeaconProxy(address(beacon), initData)));
        require(address(treasury) == predicted, "predicted proxy address mismatch");
        curve = AgentCurve(treasury.curve());
    }

    // ── Deploy / initialize ────────────────────────────────────────────────

    function test_Initialize_WiresRouterRegistryStable() public view {
        assertEq(address(treasury.ROUTER()), address(router));
        assertEq(address(treasury.REGISTRY()), address(registry));
        assertEq(address(treasury.STABLE()), address(usdg));
        assertEq(treasury.PERMIT2(), PERMIT2);
    }

    // Seed $1000 split 50/50 → ~$500 AAPL + ~$500 TSLA at the marks. NAV == seed.
    function test_Deploy_BuysAtTargetWeightsViaV4() public view {
        assertApproxEqAbs(treasury.nav(), 1_000 * 1e6, 1, "nav == seed after deploy");
        assertEq(registry.valueOf(address(tokenA), tokenA.balanceOf(address(treasury))), 500 * 1e6, "AAPL ~ $500");
        assertEq(registry.valueOf(address(tokenB), tokenB.balanceOf(address(treasury))), 500 * 1e6, "TSLA ~ $500");
    }

    // ── Forked-router wire format ────────────────────────────────────────────

    // A buy through the curve routes to the v4 forked router; the router mock
    // decodes our calldata and confirms minHopPriceX36 == 0 sits in the right
    // struct slot and that funding came through Permit2.
    function test_Buy_UsesForkedRouterAndPermit2_WithZeroMinHop() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        assertTrue(router.lastMinHopWasZero(), "minHopPriceX36 decoded as 0 in the confirmed slot");
        assertGt(router.lastAmountIn(), 0, "router saw a real amountIn");
        // Treasury granted Permit2 an ERC-20 allowance on USDG (funding leg 1).
        (uint160 amt,,) = MockPermit2(PERMIT2).allowance(address(treasury), address(usdg), address(router));
        // per-swap Permit2->router allowance is consumed to 0 by the pull.
        assertEq(amt, 0, "per-swap Permit2 allowance fully consumed");
        assertGt(usdg.allowance(address(treasury), PERMIT2), 0, "treasury approved Permit2 as ERC-20 spender");
    }

    // ── Rebalance ────────────────────────────────────────────────────────────

    function test_Rebalance_ShiftsWeightsViaV4() public {
        // Go 100% AAPL, then rebalance toward it.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(10000, 0), "ipfs://all-aapl");

        uint256[] memory z = new uint256[](2);
        uint256[] memory maxSell = new uint256[](2);
        uint256[] memory maxBuy = new uint256[](2);
        maxSell[1] = type(uint256).max; // allow selling all TSLA
        maxBuy[0] = type(uint256).max; // allow buying AAPL

        vm.prank(rebalancer);
        treasury.executeRebalanceStep(maxSell, z, maxBuy, z);

        assertEq(tokenB.balanceOf(address(treasury)), 0, "TSLA fully rotated out");
        assertApproxEqRel(
            registry.valueOf(address(tokenA), tokenA.balanceOf(address(treasury))),
            treasury.nav(),
            0.01e18,
            "~all NAV now in AAPL"
        );
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    function test_Withdraw_RedeemsStableViaV4() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 500 * 1e6);
        uint256 shares = curve.buy(500 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        uint256 balBefore = usdg.balanceOf(bob);
        curve.sell(shares, bob, 0, false, block.timestamp);
        vm.stopPrank();

        assertGt(usdg.balanceOf(bob) - balBefore, 400 * 1e6, "seller received stable back via v4 sells");
    }

    // ── creator-fee split (25% platform / 75% creator) ──────────────────────

    /// Re-launch with a creator fee share set on the factory so the treasury
    /// captures it at initialize (default is 0 → the tests above cover the
    /// legacy 100%-to-platform path). Mirrors setUp's deploy block.
    function _redeployWithCreatorShare(uint16 shareBps) internal {
        factory.setCreatorFeeShareBps(shareBps);
        factory.setFeeBps(100); // base setUp zeroes it; a fee must exist to split


        EquityTreasury impl = new EquityTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));

        EquityTreasury.CurveInitParams memory ci = EquityTreasury.CurveInitParams({
            name: "Equity Alpha",
            symbol: "EQA",
            premiumCapSupply: 30_000 * 1e18,
            extraPremium: 2e18,
            stableSeed: 1_000 * 1e6,
            seeder: alice,
            recipient: alice,
            minTokenOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            EquityTreasury.initialize,
            (rebalancer, creator, address(factory), _portfolio2(5000, 5000), "ipfs://genesis", ci)
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdg.approve(predicted, ci.stableSeed);
        treasury = EquityTreasury(address(new BeaconProxy(address(beacon), initData)));
        require(address(treasury) == predicted, "predicted proxy address mismatch");
        curve = AgentCurve(treasury.curve());
    }

    function test_Init_CapturesCreatorFeeShareFromFactory() public {
        _redeployWithCreatorShare(7500);
        assertEq(treasury.creatorFeeShareBps(), 7500, "share captured at launch");
    }

    function test_Withdraw_SplitsStableFeeBetweenCreatorAndPlatform() public {
        _redeployWithCreatorShare(7500);
        address feeRecipient = factory.feeRecipient();

        // Bob buys then sells via the proven v4 path. Snapshot the recipients
        // AFTER the buy so the deltas isolate the single sell-fee event — its two
        // recipient gains are exactly the two cuts of one fee, so the 75% identity
        // holds regardless of the router's realized amount.
        vm.startPrank(bob);
        usdg.approve(address(curve), 500 * 1e6);
        uint256 shares = curve.buy(500 * 1e6, 0, new uint256[](2), bob, block.timestamp);

        uint256 platBefore = usdg.balanceOf(feeRecipient);
        uint256 creatorBefore = usdg.balanceOf(creator);
        curve.sell(shares, bob, 0, false, block.timestamp);
        vm.stopPrank();

        uint256 creatorGain = usdg.balanceOf(creator) - creatorBefore;
        uint256 platGain = usdg.balanceOf(feeRecipient) - platBefore;
        uint256 totalFee = creatorGain + platGain;
        assertGt(totalFee, 0, "a sell fee was actually collected");
        assertEq(creatorGain, (totalFee * 7500) / 10000, "creator got exactly 75% of the sell fee");
    }

    // ── Weekend / stale-feed behavior (equity-specific) ─────────────────────

    // A stale feed (weekend/after-hours) makes valueOf revert → nav() reverts:
    // the basket is never marked at a dead feed.
    function test_Nav_RevertsWhenFeedStale() public {
        _makeStale(feedA);
        vm.expectRevert();
        treasury.nav();
    }

    // Rotation must not depend on pricing: setTargetPortfolio still works while a
    // held leg's feed is stale, so the rebalancer can rotate it out.
    function test_SetTargetPortfolio_SucceedsWhenFeedStale() public {
        _makeStale(feedA);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("TSLA", address(tokenB)), "ipfs://rotate-out-stale");
        (, uint16 bpsA,) = treasury.assets("AAPL");
        (, uint16 bpsB,) = treasury.assets("TSLA");
        assertEq(bpsA, 0, "stale leg dropped to zero weight");
        assertEq(bpsB, 10000, "surviving leg full weight");
    }

    // The COMMON weekend case: a holder exits while a feed is stale. The stale
    // leg is priced by EXECUTION against the live pool (spot-sized floor), so the
    // redeemer still receives realized USDG — the exit never bricks on the dead
    // feed. (In-kind is the fallback only when the swap itself fails; see
    // test_Redeem_InKindWhenFloorBreached / the divergence test.)
    function test_Withdraw_StaleLegSellsAtExecution() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 400 * 1e6);
        uint256 shares = curve.buy(400 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        _makeStale(feedA); // AAPL feed goes stale over the weekend

        uint256 usdgBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        curve.sell(shares, bob, 0, true, block.timestamp);

        assertGt(usdg.balanceOf(bob) - usdgBefore, 0, "stale leg sold at execution, redeemer got realized USDG");
    }

    // ── Execution-priced mint / redeem (EQUITY_EXECUTION_PRICING_SPEC) ──────

    // MINT pauses when any leg feed is stale: AgentCurve.buy reads nav(), which
    // reverts MarketClosed.
    function test_Mint_RevertsMarketClosedWhenStale() public {
        _makeStale(feedA);
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(EquityTreasury.MarketClosed.selector, address(tokenA)));
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();
    }

    // MINT succeeds when all feeds fresh.
    function test_Mint_SucceedsWhenFresh() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        uint256 shares = curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();
        assertGt(shares, 0, "minted shares while market open");
    }

    // CORE manipulation-resistance property: redeem pays REALIZED proceeds, and a
    // pre-redeem spot pump does not inflate the payout (execution ignores the
    // manipulated spot — it prices at the pool, modeled here at the mark). Guard
    // left disabled so the swap actually executes; asserts no over-payout.
    function test_Redeem_RealizedUnaffectedBySpotPump() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 400 * 1e6);
        uint256 shares = curve.buy(400 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        uint256 fair = curve.quoteSellUsdc(shares); // Chainlink-based fair estimate

        // Pump both pools' spot 100×² — must not change what redeem pays.
        _pumpSpot(address(tokenA), 10);
        _pumpSpot(address(tokenB), 10);

        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        curve.sell(shares, bob, 0, false, block.timestamp);
        uint256 got = usdg.balanceOf(bob) - before;

        assertApproxEqRel(got, fair, 0.02e18, "realized proceeds unaffected by spot pump (no over-payout)");
    }

    // Divergence guard: once enabled, a pool pushed outside the band pauses MINT
    // of that leg (Diverged) and routes REDEEM of that leg to in-kind (never
    // trades into the manipulated pool).
    function test_DivergenceGuard_MintReverts_RedeemInKind() public {
        uint256 d = registry.currentDivergenceBps(address(tokenA));
        registry.setMaxDivergenceBps(uint16(d + 200)); // within band at baseline

        vm.startPrank(bob);
        usdg.approve(address(curve), 400 * 1e6);
        uint256 shares = curve.buy(400 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        _pumpSpot(address(tokenA), 4); // 4×² = 16× spot → far outside band

        // MINT of the diverged leg reverts Diverged.
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(EquityTreasury.Diverged.selector, address(tokenA)));
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        // REDEEM: diverged AAPL leg comes back in-kind, healthy TSLA leg in USDG.
        uint256 aBefore = tokenA.balanceOf(bob);
        uint256 usdgBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        curve.sell(shares, bob, 0, true, block.timestamp);
        assertGt(tokenA.balanceOf(bob) - aBefore, 0, "diverged leg returned in-kind");
        assertGt(usdg.balanceOf(bob) - usdgBefore, 0, "healthy leg still paid in USDG");
    }

    // REDEEM in-kind fallback when a leg's realized output breaches its floor
    // (router models pool fee + impact beyond the slip buffer).
    function test_Redeem_InKindWhenFloorBreached() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 400 * 1e6);
        uint256 shares = curve.buy(400 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        router.setFeeBps(2000); // 20% haircut ≫ 3% fresh buffer → every leg breaches
        uint256 aBefore = tokenA.balanceOf(bob);
        uint256 bBefore = tokenB.balanceOf(bob);
        vm.prank(bob);
        curve.sell(shares, bob, 0, true, block.timestamp);
        assertGt(
            (tokenA.balanceOf(bob) - aBefore) + (tokenB.balanceOf(bob) - bBefore),
            0,
            "floor-breaching legs settled in-kind, exit not bricked"
        );
    }

    // WEEKEND simulation: every feed stale → MINT paused (MarketClosed) while
    // REDEEM still succeeds (degrades to in-kind — underlying stays tradable).
    function test_Weekend_MintPaused_RedeemSucceeds() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 400 * 1e6);
        uint256 shares = curve.buy(400 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        _makeStale(feedA);
        _makeStale(feedB);

        // Mint paused.
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(EquityTreasury.MarketClosed.selector, address(tokenA)));
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        // Redeem still works over the weekend — execution-priced against the
        // live pool (spot-sized floor), paying realized USDG.
        uint256 usdgBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        curve.sell(shares, bob, 0, true, block.timestamp);
        assertGt(usdg.balanceOf(bob) - usdgBefore, 0, "weekend redeem pays realized USDG while mint is paused");
    }

    // ── L2 sequencer guard (EQUITY_ORACLE_HARDENING) ────────────────────────

    // Sequencer DOWN ⇒ mint reverts SequencerDown (distinct from a weekend
    // MarketClosed); execution-priced redeem still succeeds.
    function test_Sequencer_Down_MintReverts_RedeemSucceeds() public {
        vm.startPrank(bob);
        usdg.approve(address(curve), 400 * 1e6);
        uint256 shares = curve.buy(400 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        seq.setStatus(true, block.timestamp - 10_000); // sequencer down

        // Mint paused with the DISTINCT sequencer error.
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        vm.expectRevert(EquityRegistry.SequencerDown.selector);
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        // Redeem still works during the outage: the sequencer state is not on the
        // redeem path, feeds are treated as not-fresh so legs are floored off spot
        // and fill at execution (realized USDG).
        uint256 usdgBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        curve.sell(shares, bob, 0, true, block.timestamp);
        assertGt(usdg.balanceOf(bob) - usdgBefore, 0, "redeem pays realized USDG during sequencer outage");
    }

    // Sequencer just restarted (within grace) ⇒ mint reverts SequencerGracePeriod;
    // passes once grace elapses.
    function test_Sequencer_Grace_MintReverts_ThenOk() public {
        seq.setStatus(false, block.timestamp - 100); // up, but 100s < 3600s grace

        vm.startPrank(bob);
        usdg.approve(address(curve), 200 * 1e6);
        vm.expectRevert(EquityRegistry.SequencerGracePeriod.selector);
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        vm.warp(block.timestamp + 3601); // grace elapsed
        // Refresh feeds so they aren't stale after the warp.
        feedA.setAnswer(200e8);
        feedB.setAnswer(100e8);
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        uint256 shares = curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();
        assertGt(shares, 0, "mint resumes once grace elapses");
    }

    // ── Rebalance 24/7 (EQUITY_REBALANCE_ANYTIME) ───────────────────────────

    // CORE new behavior: rebalance SUCCEEDS when every feed is stale (weekend),
    // sizing off spot and flooring with the wider stale buffer — decoupled from
    // the mint MarketClosed gate.
    function test_Rebalance_SucceedsWhenAllFeedsStale() public {
        _makeStale(feedA);
        _makeStale(feedB);

        // Target 100% AAPL / 0% TSLA.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(10000, 0), "ipfs://weekend-rotate");

        uint256[] memory z = new uint256[](2);
        uint256[] memory maxSell = new uint256[](2);
        uint256[] memory maxBuy = new uint256[](2);
        maxSell[1] = type(uint256).max;
        maxBuy[0] = type(uint256).max;

        // Must NOT revert MarketClosed — rebalance runs during the weekend.
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(maxSell, z, maxBuy, z);

        assertEq(tokenB.balanceOf(address(treasury)), 0, "stale TSLA rotated out over the weekend");
        assertGt(tokenA.balanceOf(address(treasury)), 0, "AAPL grown via spot-sized weekend rebalance");
    }

    // Mint stays gated even though rebalance is not: a stale feed pauses mint.
    function test_Rebalance247_DoesNotUngateMint() public {
        _makeStale(feedA);
        vm.startPrank(bob);
        usdg.approve(address(curve), 100 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(EquityTreasury.MarketClosed.selector, address(tokenA)));
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();
    }

    // Manipulation bound: with feeds stale, a pool haircut (models a manipulated /
    // thin spot) BEYOND the stale buffer trips the per-leg floor and reverts the
    // step — the floor, not the (spot) sizing mark, bounds worst-case execution.
    // Authorized-only + floored ⇒ 24/7 is safe.
    function test_Rebalance_FloorBoundsManipulatedSpot() public {
        _makeStale(feedA);
        _makeStale(feedB);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(10000, 0), "ipfs://rotate");

        uint256[] memory z = new uint256[](2);
        uint256[] memory maxSell = new uint256[](2);
        uint256[] memory maxBuy = new uint256[](2);
        maxSell[1] = type(uint256).max;
        maxBuy[0] = type(uint256).max;

        // 20% haircut ≫ 10% stale buffer → realized < floor → the per-leg
        // amountOutMinimum (passed to the router) trips and the step reverts.
        router.setFeeBps(2000);
        vm.prank(rebalancer);
        vm.expectRevert(bytes("router: too little out"));
        treasury.executeRebalanceStep(maxSell, z, maxBuy, z);

        // 5% haircut < 10% buffer → within tolerance → succeeds.
        router.setFeeBps(500);
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(maxSell, z, maxBuy, z);
        assertEq(tokenB.balanceOf(address(treasury)), 0, "rotation completes within the floor");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _seedPoolAt(address token, uint256 valuePer1e18) internal {
        bytes32 id = V4PoolKey.toId(V4PoolKey.build(address(usdg), token, FEE, TICK_SPACING));
        stateView.setPool(id, _sqrtPriceX96For(token, valuePer1e18), 1e18);
    }

    // Multiply a pool's stored sqrtPrice by `mult` → spot value scales by mult^2.
    function _pumpSpot(address token, uint160 mult) internal {
        bytes32 id = V4PoolKey.toId(V4PoolKey.build(address(usdg), token, FEE, TICK_SPACING));
        (uint160 sqrtP,,,) = stateView.getSlot0(id);
        stateView.setPool(id, sqrtP * mult, 1e18);
    }

    // sqrtPriceX96 s.t. registry.spotValueOf(token, 1e18) ≈ valuePer1e18 (USDG).
    function _sqrtPriceX96For(address token, uint256 valuePer1e18) internal view returns (uint160) {
        uint256 q192 = uint256(1) << 192;
        uint256 sq = token < address(usdg)
            ? _sqrt((valuePer1e18 * q192) / 1e18)
            : _sqrt((uint256(1e18) * q192) / valuePer1e18);
        return uint160(sq);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function _makeStale(MockAggregator feed) internal {
        feed.setUpdatedAt(1); // ancient round; now ≫ 1 + maxPriceAge
    }

    function _portfolio2(uint16 bpsA, uint16 bpsB)
        internal
        view
        returns (EquityTreasury.AssetSpec[] memory p)
    {
        p = new EquityTreasury.AssetSpec[](2);
        p[0] = EquityTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: bpsA});
        p[1] = EquityTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: bpsB});
    }

    function _single(string memory sym, address token)
        internal
        pure
        returns (EquityTreasury.AssetSpec[] memory p)
    {
        p = new EquityTreasury.AssetSpec[](1);
        p[0] = EquityTreasury.AssetSpec({symbol: sym, token: token, bps: 10000});
    }
}
