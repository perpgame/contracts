// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockStockTreasuryFactory} from "./mocks/MockStockTreasuryFactory.sol";

contract StockCurveTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA; // AAPL
    MockStockToken tokenB; // TSLA
    MockAggregator feedA;
    MockAggregator feedB;
    StockTokenRegistry registry;
    MockSwapRouter router;
    MockStockTreasuryFactory feeRegistry;
    StockTreasury impl;
    UpgradeableBeacon beacon;
    StockTreasury treasury;
    AgentCurve curve;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    // Default protocol fee receiver in MockStockTreasuryFactory / StockTreasuryFactory.
    address constant FEE_RECIPIENT = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6; // $1000 seed -> 1000 AGENT to alice
    uint24 constant POOL_FEE = 3000;

    function setUp() public {
        usdc = new MockUSDC();
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");
        feedA = new MockAggregator(8, 1e8);
        feedB = new MockAggregator(8, 1e8);

        registry = new StockTokenRegistry(address(this), address(usdc));
        registry.addToken(address(tokenA), address(feedA), address(0), POOL_FEE, 0);
        registry.addToken(address(tokenB), address(feedB), address(0), POOL_FEE, 0);
        registry.setMinTradeStable(10e6);

        router = new MockSwapRouter(address(usdc));
        router.setFeed(address(tokenA), feedA);
        router.setFeed(address(tokenB), feedB);
        usdc.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        feeRegistry = new MockStockTreasuryFactory(address(usdc), address(router), address(registry));

        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob,   100_000 * 1e6);

        _deployAtomically();
    }

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

        treasury = StockTreasury(_deployProxyWithSeed(_portfolio2(), "ipfs://genesis", ci, alice));
        curve = AgentCurve(treasury.curve());
    }

    /// Deploy a BeaconProxy + initialize() in one call, pre-approving stable
    /// from `seeder` to the predicted proxy address so initialize() can
    /// pull the seed during construction. Pass `address(0)` for `seeder`
    /// when the caller has already set up the approval (e.g. revert tests).
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
                address(feeRegistry), portfolio, reasoningCid, ci
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

    function _portfolio2() internal view returns (StockTreasury.AssetSpec[] memory p) {
        p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});
    }

    function _emptyMinTokenOuts() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    // ─── construction (post-seed state) ────────────────────────────────────

    function test_Construction_Identifiers() public view {
        assertEq(curve.name(), "Vol Vampire");
        assertEq(curve.symbol(), "FANG");
        assertEq(address(curve.TREASURY()), address(treasury));
        assertEq(address(curve.USDC()), address(usdc));
        assertEq(curve.PREMIUM_CAP_SUPPLY(), PREMIUM_CAP_SUPPLY);
        assertEq(curve.EXTRA_PREMIUM(), EXTRA_PREMIUM);
    }

    function test_Construction_SeederHoldsInitialSupply() public view {
        // SEED stable at 1:1 anchor (6→18 dec scaled by 1e12).
        assertEq(curve.totalSupply(), SEED * 1e12);
        assertEq(curve.balanceOf(alice), SEED * 1e12);
    }

    // ─── premium curve shape ───────────────────────────────────────────────

    function test_Premium_AtZeroIsOne() public view {
        assertEq(curve.premium(0), 1e18);
    }

    function test_Premium_AtCapIsCap() public view {
        assertEq(curve.premium(PREMIUM_CAP_SUPPLY), 1e18 + EXTRA_PREMIUM);
    }

    function test_Premium_AboveCapStaysAtCap() public view {
        assertEq(curve.premium(PREMIUM_CAP_SUPPLY * 2), 1e18 + EXTRA_PREMIUM);
    }

    function test_Premium_QuadraticShape() public view {
        uint256 halfway = PREMIUM_CAP_SUPPLY / 2;
        assertApproxEqRel(curve.premium(halfway), 15e17, 1e14);
    }

    // ─── buy ──────────────────────────────────────────────────────────────

    function test_Buy_RevertsOnZeroAmount() public {
        vm.expectRevert(AgentCurve.ZeroAmount.selector);
        vm.prank(bob);
        curve.buy(0, 0, _emptyMinTokenOuts(), bob, block.timestamp);
    }

    function test_Buy_RevertsOnZeroRecipient() public {
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentCurve.InvalidAddress.selector);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), address(0), block.timestamp);
        vm.stopPrank();
    }

    function test_Buy_RevertsOnExpiredDeadline() public {
        vm.warp(1_000);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentCurve.DeadlineExpired.selector);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_Buy_MintsAgentAtAnchorAfterSeed() public {
        // After seed, supply > 0 and nav = SEED. Buying $100 should mint
        // (100 * supply / nav / premium) AGENT.
        uint256 supplyBefore = curve.totalSupply();
        uint256 navBefore = treasury.nav();

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        uint256 agentOut = curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // The 1% buy fee is skimmed first, so the mint is quoted off the net $99.
        // Premium at supplyBefore (1000 AGENT vs 30k cap, ~0.003%)
        uint256 p = curve.premium(supplyBefore);
        uint256 expected = (99e6 * supplyBefore * 1e18) / (navBefore * p);
        assertEq(agentOut, expected);
        assertEq(curve.balanceOf(bob), agentOut);
    }

    function test_Buy_RespectsMinAgentOut() public {
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        // Demand an unrealistically high mint.
        vm.expectRevert(AgentCurve.SlippageExceeded.selector);
        curve.buy(100 * 1e6, type(uint128).max, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
    }

    function test_Buy_DeploysIntoTokens() public {
        uint256 aBefore = IERC20(address(tokenA)).balanceOf(address(treasury));
        uint256 bBefore = IERC20(address(tokenB)).balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // 1% buy fee ($1) is skimmed first; the remaining $99 is split 50/50, so
        // each leg swaps $49.5 into tokens at the $1 mark → +49.5 tokens each.
        assertEq(IERC20(address(tokenA)).balanceOf(address(treasury)), aBefore + 495 * 1e17);
        assertEq(IERC20(address(tokenB)).balanceOf(address(treasury)), bBefore + 495 * 1e17);
    }

    function test_Buy_ChargesOnePercentFeeToRecipient() public {
        uint256 feeBalBefore = usdc.balanceOf(FEE_RECIPIENT);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // 1% of $100 = $1 routed to the fee receiver in stable.
        assertEq(usdc.balanceOf(FEE_RECIPIENT), feeBalBefore + 1e6);
    }

    // ─── sell ──────────────────────────────────────────────────────────────

    function test_Sell_RevertsOnZero() public {
        vm.expectRevert(AgentCurve.ZeroAmount.selector);
        vm.prank(alice);
        curve.sell(0, alice, 0, true, block.timestamp);
    }

    function test_Sell_RevertsOnExpiredDeadline() public {
        vm.warp(1_000);
        vm.expectRevert(AgentCurve.DeadlineExpired.selector);
        vm.prank(alice);
        curve.sell(1e18, alice, 0, true, block.timestamp - 1);
    }

    function test_Sell_BurnsAndPaysOutProportional() public {
        uint256 aliceSupplyBefore = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceSupplyBefore, alice, 0, true, block.timestamp);

        assertEq(curve.balanceOf(alice), 0);
        assertEq(curve.totalSupply(), 0);
        // The treasury swaps alice's token slice to stable on the router, so
        // she's paid in stable and holds no raw tokens.
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore);
        assertEq(IERC20(address(tokenA)).balanceOf(alice), 0);
        assertEq(IERC20(address(tokenB)).balanceOf(alice), 0);
    }

    function test_Sell_ChargesOnePercentFeeToRecipient() public {
        // Alice is the sole holder; selling everything realizes the full NAV
        // (SEED) as stable via the treasury's swaps, so the 1% fee is exact.
        uint256 feeBalBefore = usdc.balanceOf(FEE_RECIPIENT);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceAgent = curve.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // 1% of the $1000 NAV → $10 to the fee receiver; alice nets $990.
        assertEq(usdc.balanceOf(FEE_RECIPIENT) - feeBalBefore, SEED / 100);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, (SEED * 99) / 100);
    }

    // returnTokens = true: a leg whose pool can't fill is paid out as raw
    // stock tokens (net of the 1% fee taken in kind), so the seller still
    // exits in full and the in-kind leg isn't an untaxed exit.
    function test_Sell_ReturnTokens_PaysInKindWhenLegCannotSwap() public {
        router.setRevertToken(address(tokenB), true); // TSLA pool is dead
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        // Alice is sole holder selling everything, so her tokenB slice is the
        // whole treasury balance — that's the in-kind amount handed out.
        uint256 inKind = tokenB.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // tokenA swapped to stable (net of fee); tokenB handed over in-kind.
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "got stable from the swappable leg");
        uint256 tokenFee = inKind / 100; // 1%
        assertEq(tokenB.balanceOf(FEE_RECIPIENT), tokenFee, "1% in-kind fee skimmed in tokens");
        assertEq(tokenB.balanceOf(alice), inKind - tokenFee, "seller got the in-kind tokens net of fee");
    }

    // returnTokens = false (stable-only): a leg whose pool can't fill is
    // skipped — its tokens stay in the treasury, the seller gets only stable,
    // and the sell does NOT revert and never hands out raw tokens.
    function test_Sell_StableOnly_SkipsLegThatCannotSwap() public {
        router.setRevertToken(address(tokenB), true);
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 treasuryBBefore = tokenB.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, false, block.timestamp);

        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "paid stable from the swappable leg");
        assertEq(tokenB.balanceOf(alice), 0, "no raw tokens handed out in stable-only mode");
        assertEq(tokenB.balanceOf(address(treasury)), treasuryBBefore, "skipped leg's tokens stay in treasury");
    }

    // Stable-only: minStableOut must protect against skipped legs. With tokenB
    // skipped only ~half the notional is realizable, so demanding near-full
    // notional reverts rather than silently shortchanging the seller.
    function test_Sell_StableOnly_RespectsMinStableOutAfterSkip() public {
        router.setRevertToken(address(tokenB), true); // half the book (50/50) can't swap
        uint256 aliceAgent = curve.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(StockTreasury.SlippageExceeded.selector);
        curve.sell(aliceAgent, alice, 900 * 1e6, false, block.timestamp);
    }

    // The fee recipient is read live from the factory, so redirecting it (e.g.
    // off a blacklisted address) immediately reroutes both buy and sell fees.
    function test_Fee_FollowsFactoryRecipient() public {
        address newRecipient = address(0xFEE5);
        feeRegistry.setFeeRecipient(newRecipient);

        // Buy: $1 fee to the new recipient, not the old default.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
        assertEq(usdc.balanceOf(newRecipient), 1e6, "buy fee routed to updated recipient");
        assertEq(usdc.balanceOf(FEE_RECIPIENT), 0, "old default recipient got nothing");

        // Sell also routes its fee to the new recipient (exact amount depends on
        // post-buy NAV; just confirm it accrues there and never to the default).
        uint256 afterBuy = usdc.balanceOf(newRecipient);
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, false, block.timestamp);
        assertGt(usdc.balanceOf(newRecipient), afterBuy, "sell fee routed to updated recipient");
        assertEq(usdc.balanceOf(FEE_RECIPIENT), 0, "default recipient never received fees");
    }

    // The fee rate is read live from the factory and applied to trades.
    function test_Fee_BpsConfigurable() public {
        feeRegistry.setFeeBps(200); // 2%

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(FEE_RECIPIENT), 2e6, "2% buy fee applied from factory config");
    }

    function test_Sell_MinStableOutSlippage() public {
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.expectRevert(StockTreasury.SlippageExceeded.selector);
        vm.prank(alice);
        // Demand more stable notional than exists.
        curve.sell(aliceAgent, alice, type(uint128).max, true, block.timestamp);
    }

    // ─── quotes ────────────────────────────────────────────────────────────

    function test_QuoteBuy_MatchesBuyOutput() public {
        uint256 quoted = curve.quoteBuy(100 * 1e6);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        uint256 actual = curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(quoted, actual);
    }

    function test_QuoteSellNotional_MatchesPayout() public view {
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 quoted = curve.quoteSellNotional(aliceAgent);
        // At pre-mint NAV = SEED with full supply the gross notional == SEED;
        // net of the 1% sell fee the seller nets 99%.
        assertEq(quoted, (SEED * 99) / 100);
    }

    // With a zero-fee router the oracle-mark withdraw quote equals the fair
    // notional and the actual payout.
    function test_QuoteSellStable_MatchesPayout() public {
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 quoted = curve.quoteSellUsdc(aliceAgent);
        assertEq(quoted, (SEED * 99) / 100, "withdrawable quote == notional net of fee");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, false, block.timestamp);
        assertEq(usdc.balanceOf(alice) - before, quoted, "quote matches actual stable withdrawn");
    }

    // ─── premium ramp dynamics ────────────────────────────────────────────

    function test_QuoteBuy_DecreasesAsSupplyApproachesCap() public {
        // Quote at small supply (~1k AGENT, far below cap).
        uint256 quoteSmall = curve.quoteBuy(100 * 1e6);

        // Buy enough to push supply ~halfway to the premium cap.
        usdc.mint(bob, 20_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(curve), 14_000 * 1e6);
        curve.buy(14_000 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Quote again — same $100 buys fewer AGENT now (premium is up).
        uint256 quoteLarge = curve.quoteBuy(100 * 1e6);
        assertLt(quoteLarge, quoteSmall, "premium reduces AGENT/stable at higher supply");
    }

    function test_Buy_SequentialBuysReflectPriceImpact() public {
        // Two identical $1k buys. The second should mint fewer AGENT than the
        // first (NAV grows + supply grows + premium creeps up).
        usdc.mint(bob, 2_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(curve), 2_000 * 1e6);
        uint256 first = curve.buy(1_000 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        uint256 second = curve.buy(1_000 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertLt(second, first, "second buy mints fewer AGENT");
    }

    // ─── sell partial vs full ──────────────────────────────────────────────

    function test_Sell_PartialReducesSupplyProportionally() public {
        uint256 supplyBefore = curve.totalSupply();
        uint256 aliceAgent = curve.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent / 2, alice, 0, true, block.timestamp);

        assertEq(curve.totalSupply(), supplyBefore - aliceAgent / 2);
        assertEq(curve.balanceOf(alice), aliceAgent - aliceAgent / 2);
    }

    function test_Sell_RevertsWhenNoSupply() public {
        // Alice is the only holder; drain entirely. Cache the balance BEFORE
        // vm.prank, since `curve.balanceOf(alice)` would otherwise consume the
        // prank as an external call.
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);
        assertEq(curve.totalSupply(), 0);

        // Now a sell attempt from bob (who has 0 AGENT) reverts with NoSupply
        // (the supplyBefore == 0 check fires before the burn).
        vm.prank(bob);
        vm.expectRevert(AgentCurve.NoSupply.selector);
        curve.sell(1, bob, 0, true, block.timestamp);
    }

    // A paid buy must never mint 0 AGENT. Reachable only in a collapsed-supply,
    // inflated-nav state: drive supply down to 1 wei (premium(1) == ONE), then
    // inflate nav with a donation so a small stableIn floors the quote to 0. A
    // buyer passing minAgentOut == 0 would otherwise pay and receive nothing.
    function test_Buy_RevertsWhenQuoteFloorsToZero() public {
        // Collapse supply to 1 wei (alice is the sole holder post-genesis).
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent - 1, alice, 0, true, block.timestamp);
        assertEq(curve.totalSupply(), 1, "supply collapsed to 1 wei");

        // Inflate nav (counts the treasury's idle stable) far above the buy size,
        // so quote = stableIn * 1 * 1e18 / (nav * premium(1)) = stableIn / nav = 0.
        usdc.mint(address(treasury), 10_000 * 1e6);
        assertEq(curve.quoteBuy(100 * 1e6), 0, "quote floors to zero");

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentCurve.ZeroAgentOut.selector);
        curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();
    }

    // ─── construction guards ───────────────────────────────────────────────

    function test_Construction_RejectsExcessivePremium() public {
        // Try to deploy a fresh treasury+curve with extraPremium > MAX.
        // Pre-approve so the initialize() seed-pull doesn't fail first;
        // the curve constructor (inside initialize) is what we want to
        // see revert.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, SEED);

        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: 101e18,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (rebalancer, creator, address(feeRegistry), _portfolio2(), "ipfs://test", ci)
        );
        vm.expectRevert(
            abi.encodeWithSelector(AgentCurve.ExtraPremiumTooHigh.selector, uint256(101e18), uint256(4e18))
        );
        new BeaconProxy(address(beacon), initData);
    }

    // The new 5× cap (4e18) is exactly at the boundary and must still deploy;
    // the reject side (one wei over) is covered by RejectsExcessivePremium.
    function test_Construction_PremiumAtCapDeploys() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, SEED);
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X", premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: 4e18, stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });
        StockTreasury t = StockTreasury(address(new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                StockTreasury.initialize,
                (rebalancer, creator, address(feeRegistry), _portfolio2(), "ipfs://ok", ci)
            )
        )));
        assertEq(AgentCurve(t.curve()).EXTRA_PREMIUM(), 4e18, "5x launch deploys at the cap");
    }

    function test_Construction_RejectsZeroSeed() public {
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            stableSeed: 0, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (rebalancer, creator, address(feeRegistry), _portfolio2(), "ipfs://test", ci)
        );
        vm.expectRevert(StockTreasury.ZeroAmount.selector);
        new BeaconProxy(address(beacon), initData);
    }

    // The factory is the live source of the pause flag, fee config, and infra
    // addresses, so a treasury must never be initialized without one.
    function test_Construction_RejectsZeroFactory() public {
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: alice, recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (rebalancer, creator, address(0), _portfolio2(), "ipfs://test", ci)
        );
        vm.expectRevert(StockTreasury.InvalidAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    // ─── nav-supply invariant across buy + sell ───────────────────────────

    function test_BuyThenSell_NavPerSupplyRoughlyPreserved() public {
        // A buy + immediate sell by the same actor should net to ~zero loss
        // (the mock router charges no fee, so this is exact). The buyer
        // effectively round-trips at the premium.
        uint256 navPerSupplyBefore = (treasury.nav() * 1e18) / curve.totalSupply();

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        uint256 minted = curve.buy(100 * 1e6, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        curve.sell(minted, bob, 0, true, block.timestamp);
        vm.stopPrank();

        uint256 navPerSupplyAfter = (treasury.nav() * 1e18) / curve.totalSupply();
        // Existing holders' per-AGENT value never decreases (premium accrues
        // to NAV, never drained).
        assertGe(navPerSupplyAfter, navPerSupplyBefore, "nav/supply does not decrease");
    }
}
