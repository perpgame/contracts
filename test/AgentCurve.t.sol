// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockBounceLT} from "./mocks/MockBounceLT.sol";
import {MockBounceFactory} from "./mocks/MockBounceFactory.sol";
import {MockLeveragedTokenHelper} from "./mocks/MockLeveragedTokenHelper.sol";
import {MockTreasuryFactory} from "./mocks/MockTreasuryFactory.sol";

contract AgentCurveTest is Test {
    MockUSDC usdc;
    MockBounceLT ltA;
    MockBounceLT ltB;
    MockBounceFactory factory;
    MockLeveragedTokenHelper helper;
    MockTreasuryFactory feeRegistry;
    AgentTreasury impl;
    UpgradeableBeacon beacon;
    AgentTreasury treasury;
    AgentCurve curve;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    // Hardcoded protocol fee receiver in AgentCurve / AgentTreasury.
    address constant FEE_RECIPIENT = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6; // $1000 seed -> 1000 AGENT to alice

    function setUp() public {
        usdc = new MockUSDC();
        ltA = new MockBounceLT("HYPE 5x Long", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        ltB = new MockBounceLT("BTC 5x Long",  "BTC5L",  address(usdc), "BTC",  5, true, 1e18);
        helper = new MockLeveragedTokenHelper();
        factory = new MockBounceFactory();
        factory.add(address(ltA));
        factory.add(address(ltB));
        feeRegistry = new MockTreasuryFactory(address(usdc), address(helper), address(factory));

        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob,   100_000 * 1e6);

        _deployAtomically();
    }

    function _deployAtomically() internal {
        impl = new AgentTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));

        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "Vol Vampire",
            symbol: "FANG",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED,
            seeder: alice,
            recipient: alice,
            minLtOuts: new uint256[](2)
        });

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        treasury = AgentTreasury(_deployProxyWithSeed(p, "ipfs://genesis", ci, alice));
        curve = AgentCurve(treasury.curve());
    }

    /// Deploy a BeaconProxy + initialize() in one call, pre-approving USDC
    /// from `seeder` to the predicted proxy address so initialize() can
    /// pull the seed during construction. Pass `address(0)` for `seeder`
    /// when the caller has already set up the approval (e.g. revert tests).
    function _deployProxyWithSeed(
        AgentTreasury.AssetSpec[] memory portfolio,
        string memory reasoningCid,
        AgentTreasury.CurveInitParams memory ci,
        address seeder
    ) internal returns (address) {
        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                rebalancer, creator,
                address(feeRegistry), portfolio, reasoningCid, ci
            )
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        if (seeder != address(0) && ci.usdcSeed > 0) {
            vm.prank(seeder);
            usdc.approve(predicted, ci.usdcSeed);
        }
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        require(address(proxy) == predicted, "predicted proxy address mismatch");
        return address(proxy);
    }

    function _emptyMinLtOuts() internal pure returns (uint256[] memory m) {
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
        // SEED USDC at 1:1 anchor (6→18 dec scaled by 1e12).
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
        curve.buy(0, 0, _emptyMinLtOuts(), bob, block.timestamp);
    }

    function test_Buy_RevertsOnZeroRecipient() public {
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentCurve.InvalidAddress.selector);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), address(0), block.timestamp);
        vm.stopPrank();
    }

    function test_Buy_RevertsOnExpiredDeadline() public {
        vm.warp(1_000);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentCurve.DeadlineExpired.selector);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_Buy_MintsAgentAtAnchorAfterSeed() public {
        // After seed, supply > 0 and nav = SEED. Buying $100 should mint
        // (100 * supply / nav / premium) AGENT.
        uint256 supplyBefore = curve.totalSupply();
        uint256 navBefore = treasury.nav();

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        uint256 agentOut = curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
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
        curve.buy(100 * 1e6, type(uint128).max, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();
    }

    function test_Buy_DeploysIntoLts() public {
        uint256 ltABefore = IERC20(address(ltA)).balanceOf(address(treasury));
        uint256 ltBBefore = IERC20(address(ltB)).balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // 1% buy fee ($1) is skimmed first; the remaining $99 is split 50/50, so
        // each leg gets $49.5 of LT at 1e18 rate → +49.5 LT each.
        assertEq(IERC20(address(ltA)).balanceOf(address(treasury)), ltABefore + 495 * 1e17);
        assertEq(IERC20(address(ltB)).balanceOf(address(treasury)), ltBBefore + 495 * 1e17);
    }

    function test_Buy_ChargesOnePercentFeeToRecipient() public {
        uint256 feeBalBefore = usdc.balanceOf(FEE_RECIPIENT);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // 1% of $100 = $1 routed to the hardcoded fee receiver in USDC.
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
        // The treasury redeems alice's LT slice to USDC (the mock LTs hold the
        // USDC), so she's paid in USDC and holds no raw LTs.
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore);
        assertEq(IERC20(address(ltA)).balanceOf(alice), 0);
        assertEq(IERC20(address(ltB)).balanceOf(alice), 0);
    }

    function test_Sell_ChargesOnePercentFeeToRecipient() public {
        // Alice is the sole holder; selling everything realizes the full NAV
        // (SEED) as USDC via the treasury's redeem, so the 1% fee is exact.
        uint256 feeBalBefore = usdc.balanceOf(FEE_RECIPIENT);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceAgent = curve.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // 1% of the $1000 NAV → $10 to the fee receiver; alice nets $990.
        assertEq(usdc.balanceOf(FEE_RECIPIENT) - feeBalBefore, SEED / 100);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, (SEED * 99) / 100);
    }

    // returnLts = true: a leg that can't be instantly redeemed is paid out as
    // raw LT tokens (net of the 1% fee taken in LT), so the seller still exits in
    // full and the in-kind leg isn't an untaxed exit.
    function test_Sell_ReturnLts_PaysInKindWhenLegCannotRedeem() public {
        ltB.setRedeemReverts(true); // BTC5L can no longer be redeemed instantly
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        // Alice is sole holder selling everything, so her ltB slice is the whole
        // treasury balance — that's the in-kind amount handed out.
        uint256 inKind = ltB.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // ltA redeemed to USDC (net of fee); ltB handed over as raw LT in-kind.
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "got USDC from the redeemable leg");
        uint256 ltFee = inKind / 100; // 1%
        assertEq(ltB.balanceOf(FEE_RECIPIENT), ltFee, "1% in-kind fee skimmed in LT");
        assertEq(ltB.balanceOf(alice), inKind - ltFee, "seller got the in-kind LT net of fee");
    }

    // returnLts = false (USDC-only): a leg that can't be instantly redeemed is
    // skipped — its LT stays in the treasury, the seller gets only USDC, and the
    // sell does NOT revert and never hands out raw LTs.
    function test_Sell_UsdcOnly_SkipsLegThatCannotRedeem() public {
        ltB.setRedeemReverts(true);
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 treasuryLtBBefore = ltB.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, false, block.timestamp);

        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "paid USDC from the redeemable leg");
        assertEq(ltB.balanceOf(alice), 0, "no raw LTs handed out in USDC-only mode");
        assertEq(ltB.balanceOf(address(treasury)), treasuryLtBBefore, "skipped leg's LT stays in treasury");
    }

    // USDC-only: minUsdcOut must protect against skipped legs. With ltB skipped
    // only ~half the notional is realizable, so demanding near-full notional
    // reverts rather than silently shortchanging the seller.
    function test_Sell_UsdcOnly_RespectsMinUsdcOutAfterSkip() public {
        ltB.setRedeemReverts(true); // half the book (50/50) can't redeem
        uint256 aliceAgent = curve.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(AgentTreasury.SlippageExceeded.selector);
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
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
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
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(FEE_RECIPIENT), 2e6, "2% buy fee applied from factory config");
    }

    // ─── creator-fee split (25% platform / 75% creator) ─────────────────────

    /// Re-launch the treasury/curve after setting a creator fee share on the
    /// factory, so the treasury captures it at initialize (as a real launch
    /// would). The default share is 0 → the existing tests above exercise the
    /// legacy 100%-to-platform path.
    function _redeployWithCreatorShare(uint16 shareBps) internal {
        feeRegistry.setCreatorFeeShareBps(shareBps);
        _deployAtomically();
    }

    function test_Init_CapturesCreatorFeeShareFromFactory() public {
        _redeployWithCreatorShare(7500);
        assertEq(treasury.creatorFeeShareBps(), 7500, "share captured at launch");
    }

    function test_Buy_SplitsFeeBetweenCreatorAndPlatform() public {
        _redeployWithCreatorShare(7500);
        uint256 platBefore = usdc.balanceOf(FEE_RECIPIENT);
        uint256 creatorBefore = usdc.balanceOf(creator);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // 1% of $100 = $1 total fee, unchanged for the trader; creator 75¢, platform 25¢.
        assertEq(usdc.balanceOf(creator) - creatorBefore, 0.75e6, "creator gets 75% of buy fee");
        assertEq(usdc.balanceOf(FEE_RECIPIENT) - platBefore, 0.25e6, "platform gets 25% of buy fee");
    }

    function test_Sell_SplitsFeeBetweenCreatorAndPlatform() public {
        _redeployWithCreatorShare(7500);
        uint256 platBefore = usdc.balanceOf(FEE_RECIPIENT);
        uint256 creatorBefore = usdc.balanceOf(creator);
        uint256 aliceAgent = curve.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // 1% of the $1000 NAV = $10 fee → creator $7.5, platform $2.5.
        uint256 fee = SEED / 100;
        uint256 creatorCut = (fee * 7500) / 10000;
        assertEq(usdc.balanceOf(creator) - creatorBefore, creatorCut, "creator gets 75% of sell fee");
        assertEq(usdc.balanceOf(FEE_RECIPIENT) - platBefore, fee - creatorCut, "platform gets 25% of sell fee");
    }

    function test_Sell_ReturnLts_SplitsInKindFee() public {
        _redeployWithCreatorShare(7500);
        ltB.setRedeemReverts(true); // BTC5L handed out in-kind (net of fee)
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 inKind = ltB.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        uint256 ltFee = inKind / 100; // 1%
        uint256 creatorCut = (ltFee * 7500) / 10000;
        assertEq(ltB.balanceOf(creator), creatorCut, "creator gets 75% of in-kind LT fee");
        assertEq(ltB.balanceOf(FEE_RECIPIENT), ltFee - creatorCut, "platform gets 25% of in-kind LT fee");
        assertEq(ltB.balanceOf(alice), inKind - ltFee, "seller still nets in-kind minus the full fee");
    }

    /// With the default 0 share (a pre-split launch), the creator receives
    /// nothing and the platform keeps the whole fee — no behavior change.
    function test_Buy_ZeroShare_AllFeeToPlatform() public {
        uint256 platBefore = usdc.balanceOf(FEE_RECIPIENT);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(creator), 0, "creator gets nothing when share is 0");
        assertEq(usdc.balanceOf(FEE_RECIPIENT) - platBefore, 1e6, "platform keeps the full fee");
    }

    function test_Sell_MinUsdcOutSlippage() public {
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.expectRevert(AgentTreasury.SlippageExceeded.selector);
        vm.prank(alice);
        // Demand more USDC notional than exists.
        curve.sell(aliceAgent, alice, type(uint128).max, true, block.timestamp);
    }

    // ─── quotes ────────────────────────────────────────────────────────────

    function test_QuoteBuy_MatchesBuyOutput() public {
        uint256 quoted = curve.quoteBuy(100 * 1e6);

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        uint256 actual = curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
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

    // When every leg can redeem instantly (default infinite buffer), the
    // withdrawable-USDC quote equals the fair-value notional and the actual payout.
    function test_QuoteSellUsdc_FullRedeemMatchesPayout() public {
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 quoted = curve.quoteSellUsdc(aliceAgent);
        assertEq(quoted, (SEED * 99) / 100, "withdrawable quote == notional net of fee");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, false, block.timestamp);
        assertEq(usdc.balanceOf(alice) - before, quoted, "quote matches actual USDC withdrawn");
    }

    // A leg that can't fit the atomic-redeem buffer is excluded from the
    // withdrawable quote (it would be skipped in a USDC-only sell), while the
    // optimistic notional still counts it.
    function test_QuoteSellUsdc_ExcludesUnbufferedLeg() public {
        helper.setBuffer(address(ltB), 0); // BTC5L can't fill atomically
        uint256 aliceAgent = curve.balanceOf(alice);

        // Only ltA's $500 slice is withdrawable → $495 net of the 1% fee.
        assertEq(curve.quoteSellUsdc(aliceAgent), (500 * 1e6 * 99) / 100, "excludes unbuffered leg");
        // Fair-value notional ignores buffers and still reflects the full $1000.
        assertEq(curve.quoteSellNotional(aliceAgent), (SEED * 99) / 100, "notional unaffected by buffer");
    }

    // ─── premium ramp dynamics ────────────────────────────────────────────

    function test_QuoteBuy_DecreasesAsSupplyApproachesCap() public {
        // Quote at small supply (~1k AGENT, far below cap).
        uint256 quoteSmall = curve.quoteBuy(100 * 1e6);

        // Buy enough to push supply ~halfway to the premium cap.
        usdc.mint(bob, 20_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(curve), 14_000 * 1e6);
        curve.buy(14_000 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Quote again — same $100 USDC buys fewer AGENT now (premium is up).
        uint256 quoteLarge = curve.quoteBuy(100 * 1e6);
        assertLt(quoteLarge, quoteSmall, "premium reduces AGENT/USDC at higher supply");
    }

    function test_Buy_SequentialBuysReflectPriceImpact() public {
        // Two identical $1k buys. The second should mint fewer AGENT than the
        // first (NAV grows + supply grows + premium creeps up).
        usdc.mint(bob, 2_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(curve), 2_000 * 1e6);
        uint256 first = curve.buy(1_000 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        uint256 second = curve.buy(1_000 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
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
    // inflate nav with a donation so a small usdcIn floors the quote to 0. A
    // buyer passing minAgentOut == 0 would otherwise pay and receive nothing.
    function test_Buy_RevertsWhenQuoteFloorsToZero() public {
        // Collapse supply to 1 wei (alice is the sole holder post-genesis).
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.prank(alice);
        curve.sell(aliceAgent - 1, alice, 0, true, block.timestamp);
        assertEq(curve.totalSupply(), 1, "supply collapsed to 1 wei");

        // Inflate nav (counts the treasury's idle USDC) far above the buy size,
        // so quote = usdcIn * 1 * 1e18 / (nav * premium(1)) = usdcIn / nav = 0.
        usdc.mint(address(treasury), 10_000 * 1e6);
        assertEq(curve.quoteBuy(100 * 1e6), 0, "quote floors to zero");

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentCurve.ZeroAgentOut.selector);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
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

        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: 101e18,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (rebalancer, creator, address(feeRegistry), p, "ipfs://test", ci)
        );
        vm.expectRevert(
            abi.encodeWithSelector(AgentCurve.ExtraPremiumTooHigh.selector, uint256(101e18), uint256(4e18))
        );
        new BeaconProxy(address(beacon), initData);
    }

    // The new 5× cap (4e18) is exactly at the boundary and must still deploy;
    // the reject side (one wei over) is covered by RejectsExcessivePremium.
    function test_Construction_PremiumAtCapDeploys() public {
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, SEED);
        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X", premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: 4e18, usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });
        AgentTreasury t = AgentTreasury(address(new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                AgentTreasury.initialize,
                (rebalancer, creator, address(feeRegistry), p, "ipfs://ok", ci)
            )
        )));
        assertEq(AgentCurve(t.curve()).EXTRA_PREMIUM(), 4e18, "5x launch deploys at the cap");
    }

    function test_Construction_RejectsZeroSeed() public {
        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            usdcSeed: 0, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (rebalancer, creator, address(feeRegistry), p, "ipfs://test", ci)
        );
        vm.expectRevert(AgentTreasury.ZeroAmount.selector);
        new BeaconProxy(address(beacon), initData);
    }

    // The factory is the live source of the pause flag and fee config, so a
    // treasury must never be initialized without one.
    function test_Construction_RejectsZeroFactory() public {
        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (rebalancer, creator, address(0), p, "ipfs://test", ci)
        );
        vm.expectRevert(AgentTreasury.InvalidAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    // ─── nav-supply invariant across buy + sell ───────────────────────────

    function test_BuyThenSell_NavPerSupplyRoughlyPreserved() public {
        // A buy + immediate sell by the same actor should net to ~zero loss
        // (mock LTs have no fees, so this is exact). The buyer effectively
        // round-trips at the premium.
        uint256 navPerSupplyBefore = (treasury.nav() * 1e18) / curve.totalSupply();

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        uint256 minted = curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        curve.sell(minted, bob, 0, true, block.timestamp);
        vm.stopPrank();

        uint256 navPerSupplyAfter = (treasury.nav() * 1e18) / curve.totalSupply();
        // Existing holders' per-AGENT value never decreases (premium accrues
        // to NAV, never drained).
        assertGe(navPerSupplyAfter, navPerSupplyBefore, "nav/supply does not decrease");
    }
}
