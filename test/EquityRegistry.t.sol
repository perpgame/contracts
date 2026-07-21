// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EquityRegistry} from "../src/EquityRegistry.sol";
import {V4PoolKey} from "../src/libraries/V4PoolKey.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockSequencerFeed} from "./mocks/MockSequencerFeed.sol";

/// Chainlink valuation + v4 route resolution for the equity registry. This is
/// the revived pre-pivot Chainlink math (git 620c571), so the value/scale/
/// staleness assertions mirror the original StockTokenRegistry tests; routing
/// (poolKey/poolId) is new. Fully implemented — unlike the treasury swap tests,
/// nothing here depends on the unverified forked-router ABI.
contract EquityRegistryTest is Test {
    EquityRegistry registry;
    MockStateView stateView;
    MockUSDC usdg; // 6-dec stable
    MockStockToken aapl; // 18-dec equity token
    MockAggregator feed; // 8-dec USD feed
    MockSequencerFeed seq; // L2 sequencer uptime feed

    address owner = address(this);
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint32 constant HB = 86_400; // 24h heartbeat

    function setUp() public {
        vm.warp(1_700_000_000);
        usdg = new MockUSDC();
        aapl = new MockStockToken("Apple Stock", "AAPL");
        feed = new MockAggregator(8, 200e8); // $200.00
        stateView = new MockStateView();
        seq = new MockSequencerFeed(0, 1); // up, started long ago (past grace)

        registry = new EquityRegistry(owner, address(usdg), address(stateView), address(seq));

        // Pre-seed the exact pool the registry will look up as initialized.
        V4PoolKey.PoolKey memory key = V4PoolKey.build(address(usdg), address(aapl), FEE, TICK_SPACING);
        stateView.setPool(V4PoolKey.toId(key), uint160(1 << 96), 1e18);

        registry.addToken(address(aapl), address(feed), FEE, TICK_SPACING, HB);
    }

    // 1 AAPL (1e18) at $200, 8-dec feed, 6-dec stable → $200 = 200e6.
    function test_ValueOf_ScalesDecimals() public view {
        assertEq(registry.valueOf(address(aapl), 1e18), 200e6, "1 AAPL == $200");
        assertEq(registry.valueOf(address(aapl), 0.5e18), 100e6, "half AAPL == $100");
    }

    // amountOf is the inverse of valueOf at the same mark.
    function test_AmountOf_InvertsValueOf() public view {
        assertEq(registry.amountOf(address(aapl), 200e6), 1e18, "$200 == 1 AAPL");
    }

    function test_ValueOf_RevertsOnStaleFeed() public {
        feed.setUpdatedAt(1); // ancient
        vm.warp(1 + 5 days + 1);
        vm.expectRevert(abi.encodeWithSelector(EquityRegistry.StalePrice.selector, address(aapl), 1));
        registry.valueOf(address(aapl), 1e18);
    }

    function test_ValueOf_RevertsOnNonPositiveAnswer() public {
        feed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(EquityRegistry.InvalidPrice.selector, address(aapl)));
        registry.valueOf(address(aapl), 1e18);
    }

    // A weekday-overnight-old feed (within maxPriceAge ~25h) still prices.
    function test_ValueOf_OkWhenWithinMaxPriceAge() public {
        vm.warp(block.timestamp + 20 hours);
        assertEq(registry.valueOf(address(aapl), 1e18), 200e6, "20h-old feed still fresh (<25h)");
    }

    function test_AddToken_RevertsWhenPoolUninitialized() public {
        MockStockToken tsla = new MockStockToken("Tesla", "TSLA");
        // No stateView.setPool → sqrtPrice 0 → PoolNotInitialized.
        vm.expectRevert();
        registry.addToken(address(tsla), address(feed), FEE, TICK_SPACING, HB);
    }

    function test_AddToken_RevertsOnZeroHeartbeat() public {
        MockStockToken tsla = new MockStockToken("Tesla", "TSLA");
        _seed(address(tsla));
        vm.expectRevert(EquityRegistry.InvalidHeartbeat.selector);
        registry.addToken(address(tsla), address(feed), FEE, TICK_SPACING, 0);
    }

    function test_PoolKey_CurrenciesSortedAscending() public view {
        V4PoolKey.PoolKey memory key = registry.poolKey(address(aapl));
        assertTrue(key.currency0 < key.currency1, "sorted ascending");
        assertEq(key.hooks, address(0), "no hook on equity pools");
        assertEq(registry.stableIsCurrency0(address(aapl)), key.currency0 == address(usdg));
    }

    // ── Sequencer uptime guard ──────────────────────────────────────────────

    function test_Sequencer_Down_ValuationReverts() public {
        seq.setStatus(true, block.timestamp - 10_000); // down
        vm.expectRevert(EquityRegistry.SequencerDown.selector);
        registry.valueOf(address(aapl), 1e18);
        assertFalse(registry.isFeedFresh(address(aapl)), "not fresh while sequencer down");
    }

    function test_Sequencer_WithinGrace_Reverts_ThenOkAfter() public {
        // Restart 100s ago → inside the 3600s grace window.
        seq.setStatus(false, block.timestamp - 100);
        vm.expectRevert(EquityRegistry.SequencerGracePeriod.selector);
        registry.valueOf(address(aapl), 1e18);
        assertFalse(registry.isFeedFresh(address(aapl)), "not fresh within grace");

        // Once grace elapses it prices again.
        vm.warp(block.timestamp + 3601);
        assertEq(registry.valueOf(address(aapl), 1e18), 200e6, "prices again past grace");
        assertTrue(registry.isFeedFresh(address(aapl)), "fresh past grace");
    }

    function test_Sequencer_OptOut_SkipsGuard() public {
        // A registry wired with address(0) never touches a sequencer feed.
        EquityRegistry r = new EquityRegistry(owner, address(usdg), address(stateView), address(0));
        _seed(address(aapl)); // pool already seeded in setUp, re-seed is idempotent
        r.addToken(address(aapl), address(feed), FEE, TICK_SPACING, HB);
        assertEq(r.valueOf(address(aapl), 1e18), 200e6, "opt-out prices normally");
        assertTrue(r.isSequencerUp(), "opt-out reports up");
    }

    // ── Per-feed heartbeat ──────────────────────────────────────────────────

    // Two assets with different cadences are each judged against their own
    // heartbeat + the global slack.
    function test_PerFeedHeartbeat_JudgedIndependently() public {
        // Fast feed: 3600s heartbeat. Slow feed (AAPL): 86400s.
        MockStockToken fastTok = new MockStockToken("Fast", "FAST");
        MockAggregator fastFeed = new MockAggregator(8, 50e8);
        _seed(address(fastTok));
        registry.addToken(address(fastTok), address(fastFeed), FEE, TICK_SPACING, 3600);

        // Age both feeds by 2 hours.
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 2 hours);

        // Fast feed: 7200s > 3600 + 3600 slack = 7200 → NOT stale at exactly the
        // boundary; push one second past to make it stale.
        assertTrue(registry.isFeedFresh(address(fastTok)), "fast feed fresh at boundary");
        vm.warp(t0 + 2 hours + 1);
        assertFalse(registry.isFeedFresh(address(fastTok)), "fast feed stale past its own window");

        // Slow feed (24h heartbeat) is comfortably fresh at ~2h old.
        assertTrue(registry.isFeedFresh(address(aapl)), "slow feed still fresh");
    }

    function _seed(address token) internal {
        bytes32 id = V4PoolKey.toId(V4PoolKey.build(address(usdg), token, FEE, TICK_SPACING));
        stateView.setPool(id, uint160(1 << 96), 1e18);
    }

    // TODO: minPoolLiquidity gate; setFeed/setRoute revalidation; disable blocks
    // new registration but keeps valuing existing holdings.
}
