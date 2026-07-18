// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockStockTreasuryFactory} from "./mocks/MockStockTreasuryFactory.sol";

contract StockTreasuryTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA; // AAPL
    MockStockToken tokenB; // TSLA
    MockRegistry registry;
    MockSwapRouter router;
    MockStockTreasuryFactory pauseRegistry;
    StockTreasury impl;
    UpgradeableBeacon beacon;
    StockTreasury treasury;
    AgentCurve curve;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6; // $1000 seed
    uint24 constant POOL_FEE = 3000;

    // ─── helpers ──────────────────────────────────────────────────────────

    function setUp() public {
        usdc = new MockUSDC();
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");

        // Both tokens marked at $1 (mark = 1e6 stable base per 1e18 token) so
        // seed numbers stay simple ($1 → 1e18 tokens per stable dollar).
        registry = new MockRegistry(address(usdc));
        registry.addToken(address(tokenA), address(0), POOL_FEE, 0);
        registry.addToken(address(tokenB), address(0), POOL_FEE, 0);
        // Mirror the old $10 venue floor so per-leg sizing expectations hold.
        registry.setMinTradeStable(10e6);

        router = new MockSwapRouter(address(usdc), address(registry));
        // Pre-fund the router so it can pay out either side of a swap.
        usdc.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        pauseRegistry = new MockStockTreasuryFactory(address(usdc), address(router), address(registry));

        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob,   100_000 * 1e6);

        _deployAtomically();
    }

    /// Deploy a BeaconProxy fronting StockTreasury, mirroring the production
    /// upgradeable flow. The BeaconProxy constructor delegatecalls initialize
    /// atomically, so the seed is pulled and deployed in the same tx.
    function _deployAtomically() internal {
        impl = new StockTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));

        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "Vol Vampire",
            symbol: "FANG",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED,
            seeder: alice,
            recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        treasury = StockTreasury(_deployProxyWithSeed(_portfolio2(5000, 5000), "ipfs://genesis", ci, alice));
        curve = AgentCurve(treasury.curve());
    }

    /// Deploy a BeaconProxy + initialize() in one call. Pre-approves stable
    /// from `seeder` to the predicted proxy address so initialize() can
    /// pull the seed during construction.
    function _deployProxyWithSeed(
        StockTreasury.AssetSpec[] memory portfolio,
        string memory reasoningCid,
        StockTreasury.CurveInitParams memory ci,
        address seeder
    ) internal returns (address) {
        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (
                rebalancer, creator,
                address(pauseRegistry), portfolio, reasoningCid, ci
            )
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        if (seeder != address(0) && ci.stableSeed > 0) {
            vm.prank(seeder);
            usdc.approve(predicted, ci.stableSeed);
        }
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        require(address(proxy) == predicted, "predicted proxy address mismatch");
        return address(proxy);
    }

    function _portfolio2(uint16 bpsA, uint16 bpsB)
        internal view returns (StockTreasury.AssetSpec[] memory p)
    {
        p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: bpsA});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: bpsB});
    }

    function _single(string memory sym, address token)
        internal pure returns (StockTreasury.AssetSpec[] memory p)
    {
        p = new StockTreasury.AssetSpec[](1);
        p[0] = StockTreasury.AssetSpec({symbol: sym, token: token, bps: 10000});
    }

    function _emptyMinTokenOuts() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    function _wide() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
    }

    function _zeros1() internal pure returns (uint256[] memory m) {
        m = new uint256[](1);
    }

    function _wide1() internal pure returns (uint256[] memory m) {
        m = new uint256[](1);
        m[0] = type(uint256).max;
    }

    /// Create a fresh token at a $1 mark, register it and pre-fund the router.
    function _addStock(string memory name_, string memory sym) internal returns (MockStockToken t) {
        t = new MockStockToken(name_, sym);
        registry.addToken(address(t), address(0), POOL_FEE, 0);
        t.mint(address(router), 1e30);
    }

    // ─── construction ─────────────────────────────────────────────────────

    function test_Construction_StoresConfig() public view {
        assertEq(treasury.rebalancer(), rebalancer);
        assertEq(treasury.CREATOR(), creator);
        assertEq(address(treasury.STABLE()), address(usdc));
        assertEq(address(treasury.REGISTRY()), address(registry));
        assertEq(address(treasury.SWAP_ROUTER()), address(router));
        assertTrue(treasury.curve() != address(0));
    }

    function test_Construction_SeedsCurveAtomically() public view {
        // Curve has SEED-scaled AGENT minted to seeder, no race window.
        assertEq(curve.totalSupply(), SEED * 1e12);
        assertEq(curve.balanceOf(alice), SEED * 1e12);
        // Treasury holds stock tokens worth `SEED` stable across the two legs.
        assertApproxEqAbs(IERC20(address(tokenA)).balanceOf(address(treasury)), 500 * 1e18, 1);
        assertApproxEqAbs(IERC20(address(tokenB)).balanceOf(address(treasury)), 500 * 1e18, 1);
    }

    // ─── multi-hop routing ─────────────────────────────────────────────────

    /// A stock token with NO direct stable pool routes stable → WETH → token on
    /// the way in and token → WETH → stable on the way out. A buy (deploy) then
    /// a full sell (curve exit) must both clear through the packed two-hop path
    /// and move holdings/NAV exactly as a direct token does at the oracle mark.
    function test_TwoHop_BuyAndSell_EndToEnd() public {
        address weth = address(0xE7A);
        MockStockToken twoHop = new MockStockToken("Two Hop Stock", "HOP");
        registry.addToken(address(twoHop), weth, 500, 3000); // $1 mark, like the others
        twoHop.mint(address(router), 1e30);

        // Sanity: the registry really hands out a two-hop path, so the swap
        // below is genuinely exercising exactInput's path decode.
        assertEq(
            registry.buyPath(address(twoHop)),
            abi.encodePacked(address(usdc), uint24(500), weth, uint24(3000), address(twoHop)),
            "buyPath is two-hop"
        );

        // Fresh single-asset treasury holding only the two-hop token.
        impl = new StockTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "Hop",
            symbol: "HOP",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED,
            seeder: alice,
            recipient: alice,
            minTokenOuts: new uint256[](1)
        });
        StockTreasury hopTreasury =
            StockTreasury(_deployProxyWithSeed(_single("HOP", address(twoHop)), "ipfs://hop", ci, alice));
        AgentCurve hopCurve = AgentCurve(hopTreasury.curve());

        // BUY leg cleared through the two-hop path during deploy.
        uint256 held = twoHop.balanceOf(address(hopTreasury));
        assertGt(held, 0, "two-hop buy delivered the token");
        assertApproxEqAbs(hopTreasury.nav(), SEED, 2, "nav ~= seed at oracle mark");

        // SELL the entire position back through the reverse two-hop path.
        uint256 aliceAgent = hopCurve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        hopCurve.sell(aliceAgent, alice, 0, false, block.timestamp);

        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "two-hop sell returned stable");
        assertEq(twoHop.balanceOf(address(hopTreasury)), 0, "position fully unwound");
    }

    function test_Construction_AbsorbsPreDonatedStable() public {
        // Anyone can dust the treasury between deploy txs in production. With
        // the constructor seed pattern that dust is folded into the seeder's
        // share (their per-AGENT NAV is slightly higher), not bricked.
        usdc.mint(bob, 1_000 * 1e6);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        // Bob donates $50 to the treasury address before deploy.
        vm.prank(bob);
        usdc.transfer(predicted, 50 * 1e6);

        // Alice seeds normally.
        vm.prank(alice);
        usdc.approve(predicted, SEED);

        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        StockTreasury t2 = StockTreasury(_deployProxyWithSeed(
            _portfolio2(5000, 5000), "ipfs://test", ci, address(0)
        ));
        AgentCurve c2 = AgentCurve(t2.curve());

        // Alice still gets SEED*1e12 AGENT. The $50 donation was deployed into
        // stock tokens, so total nav exceeds SEED by ~$50.
        assertEq(c2.balanceOf(alice), SEED * 1e12);
        assertGt(t2.nav(), SEED);
    }

    function test_Construction_RevertsOnZeroAddressArgs() public {
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (
                address(0), creator,
                address(pauseRegistry), _portfolio2(5000, 5000), "ipfs://test", ci
            )
        );
        vm.expectRevert(StockTreasury.InvalidAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_Construction_RevertsOnZeroFactory() public {
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (
                rebalancer, creator,
                address(0), _portfolio2(5000, 5000), "ipfs://test", ci
            )
        );
        vm.expectRevert(StockTreasury.InvalidAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_Construction_RevertsWhenWeightsDontSum() public {
        StockTreasury.AssetSpec[] memory bad = new StockTreasury.AssetSpec[](2);
        bad[0] = StockTreasury.AssetSpec({symbol: "A", token: address(tokenA), bps: 4000});
        bad[1] = StockTreasury.AssetSpec({symbol: "B", token: address(tokenB), bps: 4000});

        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (
                rebalancer, creator,
                address(pauseRegistry), bad, "ipfs://test", ci
            )
        );
        vm.expectRevert(StockTreasury.WeightsDoNotSumTo10000.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_Construction_RevertsOnTokenNotInRegistry() public {
        MockStockToken rogue = new MockStockToken("rogue", "RGE");
        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        p[1] = StockTreasury.AssetSpec({symbol: "RGE",  token: address(rogue),  bps: 5000});

        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (
                rebalancer, creator,
                address(pauseRegistry), p, "ipfs://test", ci
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(StockTreasury.TokenNotAllowed.selector, address(rogue))
        );
        new BeaconProxy(address(beacon), initData);
    }

    // ─── deployStable ─────────────────────────────────────────────────────

    function test_DeployStable_OnlyCurve() public {
        vm.expectRevert(StockTreasury.NotCurve.selector);
        vm.prank(alice);
        treasury.deployUsdc(100 * 1e6, _emptyMinTokenOuts());
    }

    // The factory-level global pause halts both buys and sells; unpausing
    // restores them. The treasury reads pause from its TREASURY_FACTORY ref.
    function test_Pause_HaltsBuysAndSells_ThenResumes() public {
        pauseRegistry.setPaused(true);

        // Buy reverts at deployStable's whenNotPaused guard.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(StockTreasury.Paused.selector);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Sell reverts at withdrawAssetsTo's whenNotPaused guard.
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.expectRevert(StockTreasury.Paused.selector);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // Unpause → both work again.
        pauseRegistry.setPaused(false);
        vm.startPrank(bob);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
        assertGt(curve.balanceOf(bob), 0, "buy works after unpause");

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp); // does not revert
    }

    function test_Pause_TreasuryStoresFactoryRef() public view {
        assertEq(treasury.TREASURY_FACTORY(), address(pauseRegistry));
    }

    // Rebalances are atomic now — there is no in-flight state, so buys and
    // sells work immediately after (and between) rebalance steps.
    function test_BuysAndSellsWorkImmediatelyAfterRebalanceStep() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinTokenOuts();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);

        // Buy right after the step.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
        assertGt(curve.balanceOf(bob), 0, "buy not blocked by rebalance");

        // Sell right after the step.
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);
        assertEq(curve.balanceOf(alice), 0, "sell not blocked by rebalance");
    }

    // ─── symbol pruning (unbounded-growth fix) ─────────────────────────────

    // A symbol dropped from the target (bps→0) and fully exited via a swap is
    // removed from `symbols` in the same executeRebalanceStep.
    function test_Prune_RemovesFullyExitedSymbol() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("AAPL", address(tokenA)), "ipfs://drop-b");

        uint256[] memory zeros = _emptyMinTokenOuts(); // length 2 (A,B both registered at entry)
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);

        assertEq(treasury.assetCount(), 1, "B should be pruned after full exit");
        assertEq(treasury.symbols(0), "AAPL", "A should remain");
        (, , bool registered) = treasury.assets("TSLA");
        assertFalse(registered, "TSLA should be deregistered");
        // Treasury holds no TSLA dust.
        assertEq(IERC20(address(tokenB)).balanceOf(address(treasury)), 0, "no dust left");
    }

    // The core regression: rotating assets keeps `symbols.length` at the active
    // set size, not the cumulative count. Without pruning this would climb 2→3→4…
    function test_Prune_RotationKeepsCountBounded() public {
        MockStockToken tokenC = _addStock("Nvidia Stock", "NVDA");

        uint256[] memory z3 = new uint256[](3);
        uint256[] memory w3 = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) w3[i] = type(uint256).max;

        // Rotate [A,B] → [A,C]: drops B, adds C. symbols = [A,B,C] at entry.
        StockTreasury.AssetSpec[] memory p1 = new StockTreasury.AssetSpec[](2);
        p1[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        p1[1] = StockTreasury.AssetSpec({symbol: "NVDA", token: address(tokenC), bps: 5000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p1, "ipfs://rotate-1");
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(w3, z3, w3, z3);
        assertEq(treasury.assetCount(), 2, "B pruned after rotation 1");

        // Rotate [A,C] → [A,B]: drops C, re-adds B. symbols = [A,C,B] at entry.
        StockTreasury.AssetSpec[] memory p2 = new StockTreasury.AssetSpec[](2);
        p2[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        p2[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p2, "ipfs://rotate-2");
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(w3, z3, w3, z3);
        assertEq(treasury.assetCount(), 2, "count stays bounded at active-set size after rotation 2");
    }

    // ─── sweepDust (retired-leg eviction) ──────────────────────────────────

    // A retired leg (bps→0) whose token can no longer be drained through the
    // router — delisted token, dead pool — keeps balanceOf != 0 forever, so
    // _pruneExitedSymbols never fires. Worse, the sell loop's swap of that leg
    // reverts, so the delisted leg bricks executeRebalanceStep entirely.
    // sweepDust evicts it without touching the router, sending the stranded
    // balance to CREATOR, and unblocks rebalances.
    function test_SweepDust_EvictsUndrainableRetiredLeg() public {
        uint256[] memory zeros = _emptyMinTokenOuts();

        // Drop B (bps→0); B stays registered with its full balance.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("AAPL", address(tokenA)), "ipfs://drop-b");

        // B's token is delisted: its pool is dead and the registry no longer
        // reports it as live. Its balance can never reach 0 through a swap.
        registry.setEnabled(address(tokenB), false);
        router.setRevertToken(address(tokenB), true);
        uint256 stranded = tokenB.balanceOf(address(treasury));
        assertGt(stranded, 0, "treasury holds an undrainable B position");

        // The retired-but-undrainable leg bricks executeRebalanceStep: the sell
        // loop hits B's reverting swap.
        vm.prank(rebalancer);
        vm.expectRevert(bytes("pool dead"));
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);

        // sweepDust evicts B without touching the router, forwarding its
        // balance to CREATOR.
        uint256 creatorBefore = tokenB.balanceOf(creator);
        vm.prank(rebalancer);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit StockTreasury.DustSwept("TSLA", address(tokenB), stranded);
        treasury.sweepDust("TSLA");

        assertEq(treasury.assetCount(), 1, "B evicted by sweepDust");
        assertEq(treasury.symbols(0), "AAPL", "A remains");
        (, , bool registered) = treasury.assets("TSLA");
        assertFalse(registered, "TSLA deregistered");
        assertEq(tokenB.balanceOf(creator), creatorBefore + stranded, "stranded balance to CREATOR");
        assertEq(tokenB.balanceOf(address(treasury)), 0, "treasury cleared of B");

        // Rebalance is unblocked now that the bricking leg is gone (single-symbol
        // arrays since only AAPL remains).
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide1(), _zeros1(), _wide1(), _zeros1());
        assertEq(treasury.assetCount(), 1, "rebalance succeeds post-sweep");
    }

    function test_SweepDust_RejectsStillSwappableLeg() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("AAPL", address(tokenA)), "ipfs://drop-b");

        // B is registry-listed and its $500 residual clears minTradeStable, so
        // it must be drained through a swap, not swept.
        vm.expectRevert(
            abi.encodeWithSelector(StockTreasury.SymbolStillSwappable.selector, "TSLA")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("TSLA");
    }

    function test_SweepDust_AllowsRegistryListedBelowMinDust() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("AAPL", address(tokenA)), "ipfs://drop-b");

        uint256 dustValue = registry.valueOf(address(tokenB), tokenB.balanceOf(address(treasury)));
        // sweepDust gates on minTradeStable, so raise the floor above the
        // residual's value to make this below-min position sweepable.
        registry.setMinTradeStable(dustValue + 1);

        uint256 swept = tokenB.balanceOf(address(treasury));
        vm.prank(rebalancer);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit StockTreasury.DustSwept("TSLA", address(tokenB), swept);
        treasury.sweepDust("TSLA");

        assertEq(tokenB.balanceOf(address(treasury)), 0, "treasury cleared below-min dust");
        assertEq(tokenB.balanceOf(creator), swept, "dust sent to creator");
    }

    function test_SweepDust_OnlyRebalancer() public {
        vm.expectRevert(StockTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.sweepDust("TSLA");
    }

    function test_SweepDust_RejectsActiveLeg() public {
        // TSLA is at 5000 bps — active. Sweeping it must revert.
        vm.expectRevert(
            abi.encodeWithSelector(StockTreasury.SymbolStillActive.selector, "TSLA")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("TSLA");
    }

    function test_SweepDust_RejectsUnknownSymbol() public {
        vm.expectRevert(
            abi.encodeWithSelector(StockTreasury.UnknownSymbol.selector, "NOPE")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("NOPE");
    }

    // ─── withdrawAssetsTo ──────────────────────────────────────────────────

    function test_WithdrawAssetsTo_OnlyCurve() public {
        vm.expectRevert(StockTreasury.NotCurve.selector);
        vm.prank(alice);
        treasury.withdrawLtsTo(alice, 1, 1, 0, true);
    }

    function test_WithdrawAssetsTo_SwapsToStable() public {
        // Curve does buys via deployStable — push a real buy + sell flow.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 bobAgent = curve.balanceOf(bob);
        assertGt(bobAgent, 0);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        // Sell — treasury has no idle stable, so the deficit is swapped
        // leg-by-leg to stable on the router.
        vm.prank(bob);
        curve.sell(bobAgent, bob, 0, true, block.timestamp);

        assertGt(usdc.balanceOf(bob), bobUsdcBefore, "paid in stable via swap");
        assertEq(
            IERC20(address(tokenA)).balanceOf(bob) + IERC20(address(tokenB)).balanceOf(bob),
            0,
            "no raw tokens when the swap fills"
        );
    }

    // Idle stable is paid pro-rata, not idle-first. With enough idle to have
    // covered the whole notional in cash, a seller must still take their
    // proportional token slice rather than an all-cash exit that leaves the
    // tokens (and their swap costs) to other holders.
    function test_WithdrawAssetsTo_PaysIdleProRataNotIdleFirst() public {
        // Park $2000 idle: treasury = $500 A + $500 B + $2000 idle, nav = $3000.
        usdc.mint(address(treasury), 2000 * 1e6);

        uint256 aBefore = tokenA.balanceOf(address(treasury));
        uint256 bBefore = tokenB.balanceOf(address(treasury));

        // Alice sells 1/3 of supply → notional ≈ $1000, which fits in $2000 idle.
        uint256 sellAmount = curve.balanceOf(alice) / 3;
        vm.prank(alice);
        curve.sell(sellAmount, alice, 0, true, block.timestamp);

        // Idle-first would leave the tokens untouched; pro-rata takes ~1/3 of each leg.
        assertApproxEqRel(tokenA.balanceOf(address(treasury)), (aBefore * 2) / 3, 0.01e18, "A slice taken pro-rata");
        assertApproxEqRel(tokenB.balanceOf(address(treasury)), (bBefore * 2) / 3, 0.01e18, "B slice taken pro-rata");
        // Idle was paid only pro-rata (~$666), not drained to the full $1000.
        assertGt(usdc.balanceOf(address(treasury)), 1000 * 1e6, "idle paid pro-rata, not idle-first");
    }

    // returnTokens = true: when the router is dead, every leg's swap reverts
    // and the catch path hands the seller raw stock tokens (net of the fee,
    // taken in kind) instead of bricking the exit.
    function test_WithdrawAssetsTo_ReturnsRawTokensWhenRouterDead() public {
        router.setRevertAll(true);

        uint256 aliceAgent = curve.balanceOf(alice);
        assertGt(aliceAgent, 0);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        address feeRecipient = pauseRegistry.feeRecipient();

        // Alice is the sole holder: her slice is each leg's full 500e18.
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "no stable: swaps couldn't fill");
        // 1% fee taken in kind, remainder to the seller.
        assertEq(tokenA.balanceOf(feeRecipient), 5e18, "1% in-kind fee on A");
        assertEq(tokenB.balanceOf(feeRecipient), 5e18, "1% in-kind fee on B");
        assertEq(tokenA.balanceOf(alice), 495e18, "raw A tokens to seller");
        assertEq(tokenB.balanceOf(alice), 495e18, "raw B tokens to seller");
        assertEq(tokenA.balanceOf(address(treasury)), 0, "treasury drained of A");
        assertEq(tokenB.balanceOf(address(treasury)), 0, "treasury drained of B");
    }

    // returnTokens = false: with the router dead the seller wanted stable
    // only, so failing legs are skipped — tokens stay in the treasury and the
    // seller is paid only what swapped (here: nothing).
    function test_WithdrawAssetsTo_StableOnly_LeavesTokensWhenRouterDead() public {
        router.setRevertAll(true);

        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aBefore = tokenA.balanceOf(address(treasury));
        uint256 bBefore = tokenB.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, false, block.timestamp);

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "nothing swapped, nothing paid");
        assertEq(tokenA.balanceOf(alice), 0, "no raw tokens in stable-only mode");
        assertEq(tokenB.balanceOf(alice), 0, "no raw tokens in stable-only mode");
        assertEq(tokenA.balanceOf(address(treasury)), aBefore, "A stays in treasury");
        assertEq(tokenB.balanceOf(address(treasury)), bBefore, "B stays in treasury");
        assertEq(curve.balanceOf(alice), 0, "shares still burned");
    }

    // ─── rebalancer rotation (2-step) ──────────────────────────────────────

    function test_RebalancerRotation_TwoStep() public {
        address newReb = address(0xCAFE);

        vm.prank(rebalancer);
        treasury.proposeRebalancer(newReb);
        assertEq(treasury.pendingRebalancer(), newReb);
        assertEq(treasury.rebalancer(), rebalancer, "role unchanged until accept");

        vm.prank(newReb);
        treasury.acceptRebalancer();
        assertEq(treasury.rebalancer(), newReb);
        assertEq(treasury.pendingRebalancer(), address(0));
    }

    function test_RebalancerRotation_AcceptRequiresPendingKey() public {
        vm.prank(rebalancer);
        treasury.proposeRebalancer(address(0xCAFE));

        vm.expectRevert(StockTreasury.NotPendingRebalancer.selector);
        vm.prank(alice);
        treasury.acceptRebalancer();
    }

    function test_RebalancerRotation_OverwritePending() public {
        vm.startPrank(rebalancer);
        treasury.proposeRebalancer(address(0xCAFE));
        treasury.proposeRebalancer(address(0xDEAD)); // typo fix
        vm.stopPrank();
        assertEq(treasury.pendingRebalancer(), address(0xDEAD));

        // Original wrong address can no longer accept.
        vm.expectRevert(StockTreasury.NotPendingRebalancer.selector);
        vm.prank(address(0xCAFE));
        treasury.acceptRebalancer();
    }

    function test_RebalancerRotation_OnlyRebalancerCanPropose() public {
        vm.expectRevert(StockTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.proposeRebalancer(address(0xCAFE));
    }

    // ─── setTargetPortfolio ────────────────────────────────────────────────

    function test_SetTargetPortfolio_OnlyRebalancer() public {
        vm.expectRevert(StockTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.setTargetPortfolio(_portfolio2(7000, 3000), "ipfs://x");
    }

    function test_SetTargetPortfolio_NewTokenMustBeInRegistry() public {
        // Build a new portfolio that introduces an unlisted token.
        MockStockToken rogue = new MockStockToken("rogue", "RGE");
        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](3);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 4000});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 4000});
        p[2] = StockTreasury.AssetSpec({symbol: "RGE",  token: address(rogue),  bps: 2000});

        vm.expectRevert(
            abi.encodeWithSelector(StockTreasury.TokenNotAllowed.selector, address(rogue))
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
    }

    function test_SetTargetPortfolio_AddsTokenIfAllowed() public {
        MockStockToken tokenC = _addStock("Microsoft Stock", "MSFT");

        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](3);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 4000});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 4000});
        p[2] = StockTreasury.AssetSpec({symbol: "MSFT", token: address(tokenC), bps: 2000});

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
        assertEq(treasury.assetCount(), 3);
    }

    function test_SetTargetPortfolio_OldSymbolsGrandfathered() public {
        // Zero out AAPL; symbols array should still contain it (no removal),
        // so the existing token balance stays accounted for in nav().
        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 0});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 10000});

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
        assertEq(treasury.assetCount(), 2);
        // Pre-existing AAPL position survives even though target is 0.
        assertGt(IERC20(address(tokenA)).balanceOf(address(treasury)), 0);
    }

    function test_SetTargetPortfolio_RejectsSymbolTokenSwap() public {
        // Same symbol, different token contract — must revert.
        MockStockToken tokenC = _addStock("Apple Impostor", "AAPL");

        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenC), bps: 5000});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});

        vm.expectRevert(
            abi.encodeWithSelector(
                StockTreasury.SymbolTokenMismatch.selector,
                "AAPL", address(tokenA), address(tokenC)
            )
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
    }

    // The cap is enforced against the LIVE symbols[] (active + grandfathered
    // bps=0 legs), not just the incoming portfolio. A new target whose merged set
    // would exceed MAX_ASSETS reverts, forcing the rebalancer to prune/sweep first.
    function test_SetTargetPortfolio_EnforcesMaxAssetsOnLiveArray() public {
        // setUp already registered 2 symbols (AAPL, TSLA); they linger in
        // symbols[] at bps=0 once dropped. Add MAX_ASSETS-2 new legs so the live
        // array sits exactly at the cap.
        uint16 max = treasury.MAX_ASSETS();
        uint256 newN = uint256(max) - 2;
        StockTreasury.AssetSpec[] memory full = new StockTreasury.AssetSpec[](newN);
        for (uint256 i = 0; i < newN; i++) {
            string memory sym = string(abi.encodePacked("S", vm.toString(i)));
            MockStockToken t = _addStock(sym, sym);
            uint16 bps = i == 0 ? uint16(10000 - 100 * (newN - 1)) : uint16(100);
            full[i] = StockTreasury.AssetSpec({symbol: sym, token: address(t), bps: bps});
        }
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(full, "ipfs://fill");
        assertEq(treasury.assetCount(), max, "live array == cap (incl. grandfathered AAPL/TSLA)");

        // Try to add one brand-new symbol. The merged live array would be max + 1 >
        // MAX_ASSETS → revert. The dropped legs still occupy symbols[] (not yet
        // pruned), so the cap bites.
        MockStockToken extra = _addStock("extra", "EXTRA");
        StockTreasury.AssetSpec[] memory next = new StockTreasury.AssetSpec[](2);
        next[0] = StockTreasury.AssetSpec({symbol: "S0", token: full[0].token, bps: 5000});
        // (EXTRA is the only brand-new symbol; S0 already exists.)
        next[1] = StockTreasury.AssetSpec({symbol: "EXTRA", token: address(extra), bps: 5000});
        vm.expectRevert(
            abi.encodeWithSelector(
                StockTreasury.TooManyAssets.selector, uint256(max) + 1, uint256(max)
            )
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(next, "ipfs://over");
    }

    // A NEW symbol must not be allowed to point at a token already bound to an
    // existing symbol from a PRIOR call. Without the persistent-set scan, the
    // within-array guard misses this: the duplicate token ends up in symbols[]
    // twice, nav() double-counts the one real balance, and a seller drains the
    // duplicated value via withdrawAssetsTo. (Genesis registered AAPL -> tokenA.)
    function test_SetTargetPortfolio_RejectsDuplicateTokenAcrossCalls() public {
        uint256 navBefore = treasury.nav();

        // "DUP" is a fresh symbol, but it reuses tokenA which AAPL already holds.
        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});
        p[1] = StockTreasury.AssetSpec({symbol: "DUP",  token: address(tokenA), bps: 5000});

        vm.expectRevert(
            abi.encodeWithSelector(StockTreasury.DuplicateToken.selector, address(tokenA))
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://dup");

        // State untouched: still two symbols, nav not inflated.
        assertEq(treasury.assetCount(), 2, "no duplicate symbol appended");
        assertEq(treasury.nav(), navBefore, "nav cannot be doubled");
    }

    function test_MinDeployStable_RecomputedOnTargetSet() public {
        // 50/50 → minBps=5000 → minDeployStable = ceil(10e6 * 10000 / 5000) = 20e6.
        assertEq(treasury.minDeployStable(), 20e6);
        // Shift to 99/1 → minBps=100 → minDeployStable = ceil(10e6 * 10000 / 100) = 1000e6.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://x");
        assertEq(treasury.minDeployStable(), 1000e6);
    }

    function test_MinDeployStable_TracksLiveRegistryMinTrade() public {
        registry.setMinTradeStable(25e6);
        assertEq(treasury.minDeployStable(), 50e6);

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://x");
        assertEq(treasury.minDeployStable(), 2500e6);
    }

    // ─── deploy deferral ───────────────────────────────────────────────────

    // A zeroed leg lingering in the LAST slot of symbols[] must not receive the
    // flooring remainder. Active A/B sum to 100%, so the last (zeroed) leg C
    // would get a few wei of dust; the swap-leg minTrade guard would then skip
    // it anyway, but the fix allocates it 0 and leaves the dust idle.
    function test_BuyTokens_ZeroedLastLeg_DoesNotBrickBuyOnDust() public {
        MockStockToken tokenC = _addStock("Nvidia Stock", "NVDA");

        // Register C (3-leg active) then drop it back to bps 0 — C stays in
        // symbols[] at the last index with a live token.
        StockTreasury.AssetSpec[] memory three = new StockTreasury.AssetSpec[](3);
        three[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 3400});
        three[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 3300});
        three[2] = StockTreasury.AssetSpec({symbol: "NVDA", token: address(tokenC), bps: 3300});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(three, "ipfs://add-c");
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(5000, 5000), "ipfs://drop-c");

        // Odd buy → A,B each take floor(50%) and 1 wei of remainder is left for C.
        uint256[] memory zeros3 = new uint256[](3);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100_000_001);
        curve.buy(100_000_001, 0, zeros3, bob, block.timestamp); // must not revert
        vm.stopPrank();

        assertGt(curve.balanceOf(bob), 0, "buy succeeded despite zeroed last leg");
        assertEq(tokenC.balanceOf(address(treasury)), 0, "no dust bought into the zeroed leg");
        assertLe(usdc.balanceOf(address(treasury)), 2, "remainder dust left idle");
    }

    function test_DeployStable_DeferredBelowThreshold() public {
        // Shift to 99/1 so minDeployStable balloons to $1000.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");

        // A $5 buy is far below the new threshold — stable should accumulate
        // as idle instead of being deployed into tokens.
        uint256 idleBefore = usdc.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 5 * 1e6);
        vm.expectEmit(true, true, true, false, address(treasury));
        emit StockTreasury.DeployDeferred(0, 0);
        curve.buy(5 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // $5 buy less the 1% fee ($0.05) → $4.95 lands in the treasury as idle.
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 4_950_000, "idle accumulated");
    }

    function test_DeployStable_DefersWhenMinTradeRaised() public {
        // $1000 deploy at 99/1 would give TSLA a $10 slice. Once the registry
        // floor is $11, minDeployStable rises to $1100 and the buy defers
        // before attempting any below-min swap.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");
        registry.setMinTradeStable(11 * 1e6);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 aBefore = tokenA.balanceOf(address(treasury));
        uint256 bBefore = tokenB.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 1000 * 1e6);
        // $1000 buy less the 1% fee → $990 deployable, still below the $1100 floor.
        vm.expectEmit(true, true, true, true, address(treasury));
        emit StockTreasury.DeployDeferred(990 * 1e6, 1100 * 1e6);
        curve.buy(1000 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(address(treasury)), aBefore, "no swap attempted");
        assertEq(tokenB.balanceOf(address(treasury)), bBefore, "no below-min swap attempted");
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 990 * 1e6, "buy left idle");
    }

    function test_DeployStable_DeploysOnceMinTradeIsMet() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");
        registry.setMinTradeStable(11 * 1e6);

        uint256 aBefore = tokenA.balanceOf(address(treasury));
        uint256 bBefore = tokenB.balanceOf(address(treasury));

        // Buy $1200 so that, net of the 1% fee, $1188 is deployable — above the
        // $1100 threshold, and the small leg's 1% share ($11.88) clears the $11 floor.
        vm.startPrank(bob);
        usdc.approve(address(curve), 1200 * 1e6);
        curve.buy(1200 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertGt(tokenA.balanceOf(address(treasury)), aBefore, "large leg bought");
        assertGt(tokenB.balanceOf(address(treasury)), bBefore, "small leg met live floor");
    }

    // ─── paused-token resilience ───────────────────────────────────────────

    // A single paused leg must not brick buys: its share is skipped and left
    // idle (the un-paused leg still swaps), and the buyer still receives AGENT.
    function test_Buy_SkipsPausedLeg_DoesNotRevert() public {
        // 50/50 AAPL/TSLA. Pause TSLA (tokenB).
        tokenB.setPaused(true);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 aBalBefore = tokenA.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        // Net of the 1% fee, $99 deploys; tokenB's 50% ($49.5) is skipped and stays idle.
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StockTreasury.BuySkippedPaused("TSLA", 49_500_000);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Buy succeeded: buyer holds AGENT.
        assertGt(curve.balanceOf(bob), 0, "buy minted AGENT despite paused leg");
        // tokenA (un-paused) got its $49.5; tokenB's $49.5 sits idle in the treasury.
        assertGt(tokenA.balanceOf(address(treasury)), aBalBefore, "un-paused leg bought");
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 49_500_000, "paused leg's share left idle");
        // No value lost: idle stable counts in NAV at face value.
    }

    // Once the leg un-pauses, a subsequent buy deploys both the new funds and
    // the previously-stranded idle stable into the formerly-paused leg.
    function test_Buy_DeploysIdleAfterUnpause() public {
        tokenB.setPaused(true);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
        // Net of the 1% fee: tokenB's skipped 50% share is $49.5.
        assertEq(usdc.balanceOf(address(treasury)), 49_500_000, "tokenB share idle while paused");

        // Unpause and buy again — idle stable now deploys into tokenB.
        tokenB.setPaused(false);
        uint256 bBefore = tokenB.balanceOf(address(treasury));
        vm.startPrank(alice);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), alice, block.timestamp);
        vm.stopPrank();

        assertGt(tokenB.balanceOf(address(treasury)), bBefore, "tokenB bought after unpause");
        assertLt(usdc.balanceOf(address(treasury)), 50 * 1e6, "idle drained into tokenB");
    }

    // A caller demanding exposure to a paused leg (minTokenOuts[i] != 0) must
    // get a revert, not a silent skip — the per-leg floor is honored exactly as
    // the stableToAllocate == 0 branch does.
    function test_Buy_RevertsWhenDemandingExposureToPausedLeg() public {
        tokenB.setPaused(true); // TSLA is index 1

        uint256[] memory minTokenOuts = new uint256[](2);
        minTokenOuts[1] = 1; // demand >=1 unit of the paused leg

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(StockTreasury.SlippageExceeded.selector);
        curve.buy(100 * 1e6, 0, minTokenOuts, bob, block.timestamp);
        vm.stopPrank();
    }

    // Demanding a floor on the un-paused leg while the other leg is paused still
    // succeeds: the live leg's floor is satisfied and the paused leg (floor 0)
    // is skipped to idle. Confirms the fix only reverts on the demanded leg.
    function test_Buy_DemandFloorOnLiveLeg_SkipsPausedLeg() public {
        tokenB.setPaused(true); // TSLA (index 1) paused; AAPL (index 0) live

        uint256[] memory minTokenOuts = new uint256[](2);
        minTokenOuts[0] = 1; // demand >=1 unit of the live leg, none of the paused one

        uint256 idleBefore = usdc.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StockTreasury.BuySkippedPaused("TSLA", 49_500_000);
        curve.buy(100 * 1e6, 0, minTokenOuts, bob, block.timestamp);
        vm.stopPrank();

        assertGt(curve.balanceOf(bob), 0, "buy minted AGENT");
        assertGt(tokenA.balanceOf(address(treasury)), 0, "live leg bought");
        // Net of the 1% fee, tokenB's skipped 50% share is $49.5.
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 49_500_000, "paused leg left idle");
    }

    // executeRebalanceStep skips a paused grow-leg instead of reverting the
    // whole step; the rest of the rebalance proceeds.
    function test_ExecuteRebalanceStep_SkipsPausedGrowLeg() public {
        // Target 20/80 so tokenB must GROW (buy side). Pause tokenB.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(2000, 8000), "ipfs://shift");
        tokenB.setPaused(true);

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();

        // Does not revert; emits the skip for the paused grow leg.
        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit StockTreasury.BuySkippedPaused("TSLA", 0);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        // tokenA was sold down (sell side ran); tokenB buy was skipped, stable idle.
        assertGt(usdc.balanceOf(address(treasury)), 0, "sale proceeds left idle, buy skipped");
    }

    // A paused SELL leg is skipped (SellSkippedPaused) rather than reverting
    // the whole step.
    function test_ExecuteRebalanceStep_SkipsPausedSellLeg() public {
        // Target 20/80 so tokenA must SHRINK. Pause tokenA.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(2000, 8000), "ipfs://shift");
        tokenA.setPaused(true);

        uint256 aBefore = tokenA.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();

        // A must shrink $300 → 300e18 tokens at the $1 mark.
        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StockTreasury.SellSkippedPaused("AAPL", 300e18);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertEq(tokenA.balanceOf(address(treasury)), aBefore, "paused sell leg untouched");
    }

    // Demanding a fill on a paused sell leg (minSellStable != 0) reverts
    // instead of silently skipping.
    function test_ExecuteRebalanceStep_PausedSellLegWithFillDemandReverts() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(2000, 8000), "ipfs://shift");
        tokenA.setPaused(true);

        uint256[] memory minSell = _emptyMinTokenOuts();
        minSell[0] = 1; // demand a fill on the paused leg

        vm.prank(rebalancer);
        vm.expectRevert(StockTreasury.SlippageExceeded.selector);
        treasury.executeRebalanceStep(_wide(), minSell, _wide(), _emptyMinTokenOuts());
    }

    // A leg whose required shrink is below the registry's minTradeStable must
    // be skipped, not reverted — otherwise one dust-level leg bricks the whole
    // step.
    function test_ExecuteRebalanceStep_SkipsSellLegBelowMinTrade() public {
        // 4990/5010 → tokenA must shrink ~$1 of its $500. Floor is $2, so the
        // trim is undersized. Cap tokenB's grow to 0 so the buy side is a no-op
        // and we isolate the sell-leg behaviour.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(4990, 5010), "ipfs://dust");
        registry.setMinTradeStable(2 * 1e6);

        uint256 aBefore = tokenA.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();
        uint256[] memory noBuy = _emptyMinTokenOuts(); // maxBuyStable = [0, 0]

        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit StockTreasury.SellSkippedBelowMin("AAPL", 0, 0);
        treasury.executeRebalanceStep(wide, zeros, noBuy, zeros);

        assertEq(tokenA.balanceOf(address(treasury)), aBefore, "undersized sell leg untouched");
    }

    // A grow leg below minTradeStable is likewise skipped, not reverted.
    function test_ExecuteRebalanceStep_SkipsBuyLegBelowMinTrade() public {
        // Donate idle stable so nav rises and BOTH legs sit under target (pure
        // buy side, no sell). 50/50 of a $1100 nav targets ~$550 each; we
        // instead target tokenA just $1 above its $500 holding so its grow is
        // undersized.
        usdc.mint(address(treasury), 100 * 1e6);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(4555, 5445), "ipfs://dust-buy");
        registry.setMinTradeStable(2 * 1e6);

        uint256 aBefore = tokenA.balanceOf(address(treasury));
        uint256 bBefore = tokenB.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();

        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit StockTreasury.BuySkippedBelowMin("AAPL", 0, 0);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertEq(tokenA.balanceOf(address(treasury)), aBefore, "undersized grow leg untouched");
        assertGt(tokenB.balanceOf(address(treasury)), bBefore, "well-sized grow leg still bought");
    }

    // The skip honors an explicit fill demand: a non-zero minSellStable on an
    // undersized leg still reverts, so a caller who insists on a fill is told.
    function test_ExecuteRebalanceStep_UndersizedSellWithFillDemandReverts() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(4990, 5010), "ipfs://dust");
        registry.setMinTradeStable(2 * 1e6);

        uint256[] memory wide = _wide();
        uint256[] memory noBuy = _emptyMinTokenOuts();
        uint256[] memory minSell = _emptyMinTokenOuts();
        minSell[0] = 1; // demand a fill on the undersized leg

        vm.prank(rebalancer);
        vm.expectRevert(StockTreasury.SlippageExceeded.selector);
        treasury.executeRebalanceStep(wide, minSell, noBuy, _emptyMinTokenOuts());
    }

    // ─── rebalance flow ────────────────────────────────────────────────────

    // Buy targets must be sized off the POST-sell nav, not the pre-swap
    // snapshot. Drop A entirely with a 10% router fee: the sell nets $450 of
    // A's $500, so the surviving leg B (target 100%) must grow by exactly the
    // realized proceeds — nothing stranded, nothing over-targeted.
    function test_ExecuteRebalanceStep_BuysSizedOffPostSellNav() public {
        router.setFeeBps(1000); // 10% pool fee + impact

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("TSLA", address(tokenB)), "ipfs://drop-a");

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros); // must not revert

        assertEq(treasury.assetCount(), 1, "A fully exited and pruned");
        // Sell realized $450 net; buy of $450 nets 405 tokens → nav $905.
        assertApproxEqAbs(treasury.nav(), 905 * 1e6, 1e6, "nav fell by the swap fees");
        assertApproxEqAbs(
            registry.valueOf(address(tokenB), tokenB.balanceOf(address(treasury))),
            905 * 1e6, 1e6, "B grew to the post-fee nav"
        );
        assertLe(usdc.balanceOf(address(treasury)), 1, "proceeds fully deployed, none stranded");
    }

    // A full re-weight settles atomically in a single step: sell legs swap
    // token→stable and the proceeds fund the buy legs in the same call.
    function test_ExecuteRebalanceStep_CompletesAtomicallyInOneStep() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertApproxEqAbs(
            registry.valueOf(address(tokenA), tokenA.balanceOf(address(treasury))),
            800 * 1e6, 1e6, "A at target after one step"
        );
        assertApproxEqAbs(
            registry.valueOf(address(tokenB), tokenB.balanceOf(address(treasury))),
            200 * 1e6, 1e6, "B at target after one step"
        );
        assertLe(usdc.balanceOf(address(treasury)), 1, "no stranded proceeds");
    }

    // A sell-to-fund-buy rebalance with no idle cash must not revert. The sold
    // leg delivers proceeds NET of the router fee, so the buy is short by
    // exactly the fee; the treasury buys what the proceeds actually cover.
    function test_ExecuteRebalanceStep_BuyFundedByNetProceeds_NoRevert() public {
        // Re-weight 50/50 → 80/20: sell B (~$300), buy A. No idle cash post-seed.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        router.setFeeBps(150); // 1.5%

        assertEq(usdc.balanceOf(address(treasury)), 0, "no idle cash (normal state)");
        uint256 aBefore = tokenA.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros); // must not revert

        assertGt(tokenA.balanceOf(address(treasury)), aBefore, "buy leg grew from net proceeds");
        assertLe(usdc.balanceOf(address(treasury)), 1, "net proceeds deployed into buy leg");
    }

    // Sell legs are sized via registry.amountOf: after A's mark doubles, a
    // 50/50 retarget must sell exactly the token amount whose oracle value
    // equals the excess — not a balance-proportional guess.
    function test_ExecuteRebalanceStep_SellSizedByRegistryAmountOf() public {
        // A's price doubles: A = 500e18 tokens @ $2 = $1000, B = $500, nav $1500.
        registry.setMark(address(tokenA), 2e6); // $2
        assertEq(treasury.nav(), 1500 * 1e6, "nav reflects the new mark");

        // Target 50/50 of $1500 → A target $750 → shrink $250 →
        // amountOf(A, 250e6) = 125e18 tokens.
        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit StockTreasury.TokenSold("AAPL", address(tokenA), 125e18, 250e6);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertEq(tokenA.balanceOf(address(treasury)), 375e18, "A sold exactly amountOf(shrink)");
        assertApproxEqAbs(
            registry.valueOf(address(tokenB), tokenB.balanceOf(address(treasury))),
            750 * 1e6, 1e6, "B grew to target with the proceeds"
        );
    }

    // ─── withdrawAssetsTo dual-source payout ───────────────────────────────

    function test_WithdrawAssetsTo_MixedIdleAndSwappedPayout() public {
        // Force idle accumulation: shift to 99/1, which raises minDeployStable
        // to $1000. A $50 buy defers and leaves stable idle.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");

        vm.startPrank(bob);
        usdc.approve(address(curve), 50 * 1e6);
        curve.buy(50 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Treasury now holds: ~$1000 in tokens (from alice's seed), $49.5 idle
        // stable (from bob's deferred buy). Total nav ~$1049.5.
        uint256 idle = usdc.balanceOf(address(treasury));
        assertGt(idle, 0);
        assertGt(IERC20(address(tokenA)).balanceOf(address(treasury)), 0);

        // Alice sells her entire seed share (~95% of supply → notional ~$1000).
        // Idle is paid pro-rata, the deficit is swapped from tokens to stable.
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // Entire payout is stable (idle + swapped); no raw tokens since the
        // router can cover every swap.
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore + idle, "stable = idle + swapped");
        assertEq(
            IERC20(address(tokenA)).balanceOf(alice) + IERC20(address(tokenB)).balanceOf(alice),
            0,
            "no raw tokens when the swap fills"
        );
    }

    // ─── nav() & oracle staleness ──────────────────────────────────────────

    function test_Nav_IncludesIdleStableAndTokens() public {
        // Force idle accumulation.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://x");
        vm.startPrank(bob);
        usdc.approve(address(curve), 50 * 1e6);
        curve.buy(50 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 idle = usdc.balanceOf(address(treasury));
        uint256 tokenVal = registry.valueOf(address(tokenA), tokenA.balanceOf(address(treasury)))
                         + registry.valueOf(address(tokenB), tokenB.balanceOf(address(treasury)));
        assertEq(treasury.nav(), idle + tokenVal);
    }

    // When a leg becomes unpriceable (on the real registry: too little TWAP
    // history; here: a frozen mark), every strict valuation-dependent path —
    // nav(), buys, rebalance steps — reverts rather than trading at a bad mark.
    function test_Nav_RevertsOnUnpriceableLeg() public {
        registry.setFrozen(address(tokenA), true);

        vm.expectRevert(bytes("MockRegistry: stale"));
        treasury.nav();
    }

    function test_Buy_RevertsOnUnpriceableLeg() public {
        registry.setFrozen(address(tokenA), true);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(bytes("MockRegistry: stale"));
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
    }

    // An unpriceable leg must NOT trap sellers (audit HIGH-3). With
    // returnTokens=true each leg is settled in-kind so a holder can always exit,
    // even while nav()/buy/rebalance stay frozen (see the sibling revert tests).
    function test_Sell_Unpriceable_SettlesInKind() public {
        registry.setFrozen(address(tokenA), true);
        registry.setFrozen(address(tokenB), true);

        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aBefore = tokenA.balanceOf(alice);
        uint256 bBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        assertEq(curve.balanceOf(alice), 0, "shares burned");
        assertGt(tokenA.balanceOf(alice) - aBefore, 0, "AAPL returned in-kind");
        assertGt(tokenB.balanceOf(alice) - bBefore, 0, "TSLA returned in-kind");
    }

    function test_ExecuteRebalanceStep_RevertsOnUnpriceableLeg() public {
        registry.setFrozen(address(tokenA), true);

        uint256[] memory zeros = _emptyMinTokenOuts();
        vm.prank(rebalancer);
        vm.expectRevert(bytes("MockRegistry: stale"));
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);
    }
}
