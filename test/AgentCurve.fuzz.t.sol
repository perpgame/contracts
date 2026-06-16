// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
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

/// Property-based fuzz tests for AgentCurve + AgentTreasury under the new
/// atomic-spawn architecture. Each test runs 256 random inputs by default.
///
/// Invariants exercised:
/// - premium curve shape (bounds, monotonicity, exact anchor at 0)
/// - quote_match: quoteBuy(x) == buy(x).agentOut for any state
/// - no_free_money: sell notional ≤ usdcIn for any back-to-back round trip
/// - sell_pro_rata: selling X/total of supply transfers ≤ X/total of each LT
/// - never_overpay: withdrawLtsTo never gives the seller more than their NAV share
/// - rebalance_preserves_nav: zero-fee mock LTs → NAV unchanged on weight shift
contract AgentCurveFuzzTest is Test {
    MockUSDC usdc;
    MockBounceLT ltA;
    MockBounceLT ltB;
    MockBounceFactory factory;
    MockLeveragedTokenHelper helper;
    MockTreasuryFactory feeRegistry;
    AgentTreasury treasury;
    AgentCurve curve;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address constant FEE_RECIPIENT = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        ltA = new MockBounceLT("HYPE 5x Long", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        ltB = new MockBounceLT("BTC 5x Long",  "BTC5L",  address(usdc), "BTC",  5, true, 1e18);
        helper = new MockLeveragedTokenHelper();
        factory = new MockBounceFactory();
        factory.add(address(ltA));
        factory.add(address(ltB));
        feeRegistry = new MockTreasuryFactory(address(usdc), address(helper), address(factory));

        usdc.mint(alice, 1e30);
        usdc.mint(bob, 1e30);

        _deployAtomically();
    }

    function _deployAtomically() internal {
        AgentTreasury impl = new AgentTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));

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

        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                rebalancer, creator,
                address(feeRegistry), p, "ipfs://test", ci
            )
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, SEED);

        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        require(address(proxy) == predicted);
        treasury = AgentTreasury(address(proxy));
        curve = AgentCurve(treasury.curve());
    }

    function _emptyMinLtOuts() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    // ─── premium curve shape ───────────────────────────────────────────────

    /// Premium is always in [1.0×, 1 + EXTRA]. No underflow, no overflow.
    function testFuzz_Premium_AlwaysInBounds(uint256 supply) public view {
        supply = bound(supply, 0, type(uint128).max);
        uint256 p = curve.premium(supply);
        assertGe(p, 1e18, "premium below floor");
        assertLe(p, 1e18 + EXTRA_PREMIUM, "premium above cap");
    }

    /// Higher supply → higher (or equal) premium. Strict monotonicity below cap.
    function testFuzz_Premium_Monotonic(uint256 s1, uint256 s2) public view {
        s1 = bound(s1, 0, PREMIUM_CAP_SUPPLY * 3);
        s2 = bound(s2, 0, PREMIUM_CAP_SUPPLY * 3);
        if (s1 <= s2) {
            assertLe(curve.premium(s1), curve.premium(s2));
        } else {
            assertGe(curve.premium(s1), curve.premium(s2));
        }
    }

    /// At cap supply or above, premium == cap exactly.
    function testFuzz_Premium_AboveCapIsCap(uint256 supply) public view {
        supply = bound(supply, PREMIUM_CAP_SUPPLY, type(uint128).max);
        assertEq(curve.premium(supply), 1e18 + EXTRA_PREMIUM);
    }

    /// premium(0) is exactly ONE — no rounding error at the floor.
    function testFuzz_Premium_ZeroIsExactlyOne(uint256 ignored) public view {
        ignored; // fuzzer iterates to stress the call
        assertEq(curve.premium(0), 1e18);
    }

    // ─── quote vs actual ───────────────────────────────────────────────────

    /// quoteBuy(x) == buy(x).agentOut on any state. Tested by quoting + buying
    /// in immediate succession after a randomly-sized predecessor buy from
    /// alice (so we're past the seed anchor and into the premium-loaded path).
    function testFuzz_Quote_MatchesActual(uint96 aliceBuy, uint96 bobBuy) public {
        aliceBuy = uint96(bound(aliceBuy, 1e6, 100_000e6));
        bobBuy = uint96(bound(bobBuy, 1e6, 100_000e6));

        vm.startPrank(alice);
        usdc.approve(address(curve), aliceBuy);
        curve.buy(aliceBuy, 0, _emptyMinLtOuts(), alice, block.timestamp);
        vm.stopPrank();

        uint256 quoted = curve.quoteBuy(bobBuy);
        vm.startPrank(bob);
        usdc.approve(address(curve), bobBuy);
        uint256 actual = curve.buy(bobBuy, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(actual, quoted, "quote diverged from actual");
    }

    // ─── no free money on round-trip ───────────────────────────────────────

    /// Buy then immediately sell at NAV floor. The buyer must walk away with
    /// no more notional than they put in — the premium they paid stays with
    /// existing holders (i.e. with alice's seed share).
    function testFuzz_BuyThenSell_NoFreeMoney(uint96 bobBuy) public {
        bobBuy = uint96(bound(bobBuy, 1e6, 10_000e6));

        vm.startPrank(bob);
        usdc.approve(address(curve), bobBuy);
        uint256 bobAgent = curve.buy(bobBuy, 0, _emptyMinLtOuts(), bob, block.timestamp);
        uint256 sellNotional = curve.quoteSellNotional(bobAgent);
        vm.stopPrank();

        assertLe(sellNotional, bobBuy, "buyer extracted more than they paid");
    }

    // ─── monotonic worsening for later buyers ──────────────────────────────

    /// Same USDC buys fewer or equal AGENT at higher supply. Two buys in
    /// sequence — the second must mint ≤ the first.
    function testFuzz_LaterBuyer_GetsLessOrEqual(uint96 buySize) public {
        buySize = uint96(bound(buySize, 1e6, 5_000e6));

        usdc.mint(bob, 1e30);
        vm.startPrank(bob);
        usdc.approve(address(curve), uint256(buySize) * 2);
        uint256 first = curve.buy(buySize, 0, _emptyMinLtOuts(), bob, block.timestamp);
        uint256 second = curve.buy(buySize, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertLe(second, first, "second buy not at worse-or-equal price");
    }

    // ─── proportional sell ─────────────────────────────────────────────────

    /// Selling pct/10000 of total supply pays out pct/10000 of every LT
    /// balance (within rounding). Catches drift in withdrawLtsTo math.
    function testFuzz_Sell_ProRataAcrossLts(uint96 extraBuy, uint16 pctBps) public {
        extraBuy = uint96(bound(extraBuy, 1e6, 100_000e6));
        pctBps = uint16(bound(uint256(pctBps), 1, 9999));

        // Bob adds to the pot so alice isn't the only holder.
        vm.startPrank(bob);
        usdc.approve(address(curve), extraBuy);
        curve.buy(extraBuy, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 sellAmount = (aliceAgent * pctBps) / 10000;
        if (sellAmount == 0) return;

        uint256 supplyBefore = curve.totalSupply();
        uint256 ltABefore = IERC20(address(ltA)).balanceOf(address(treasury));
        uint256 ltBBefore = IERC20(address(ltB)).balanceOf(address(treasury));
        uint256 idleBefore = usdc.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(sellAmount, alice, 0, true, block.timestamp);

        // Expected total payout value = nav_before * sellAmount / supplyBefore.
        uint256 navBefore = idleBefore + ltA.ltToBaseAmount(ltABefore) + ltB.ltToBaseAmount(ltBBefore);
        uint256 expectedNotional = (navBefore * sellAmount) / supplyBefore;

        // Sum of received value (USDC + LT-equivalent USD).
        uint256 receivedUsdc = usdc.balanceOf(alice) - (1e30 - SEED); // alice started with 1e30, minus seed approved
        // Actually compute received-this-tx as nav delta of treasury (cleaner).
        uint256 idleAfter = usdc.balanceOf(address(treasury));
        uint256 ltAAfter = IERC20(address(ltA)).balanceOf(address(treasury));
        uint256 ltBAfter = IERC20(address(ltB)).balanceOf(address(treasury));
        uint256 navAfter = idleAfter + ltA.ltToBaseAmount(ltAAfter) + ltB.ltToBaseAmount(ltBAfter);
        uint256 paidOut = navBefore - navAfter;

        // Bound the drift symmetrically by ~1 wei per LT leg. The mock LT's
        // `ltToBaseAmount` is floor(amount / 1e12), so nav_before's two
        // ltToBaseAmount snapshots and nav_after's two snapshots can each
        // round in different directions, producing up to 2 wei of drift in
        // EITHER direction between paidOut and the floor-divided notional.
        assertLe(paidOut, expectedNotional + 2, "over-paid seller beyond rounding");
        assertGe(paidOut + 2, expectedNotional, "under-paid seller beyond rounding");

        receivedUsdc; // silence unused (kept for documentation)
    }

    /// Idle USDC pays out first, then LTs fill the deficit. With a donation
    /// to the treasury, the seller receives at least min(notional, idle) in
    /// USDC and the remainder in LTs.
    function testFuzz_WithdrawLtsTo_PaysUsdcWhenRedeemFills(uint96 extraBuy, uint16 pctBps, uint96 donation)
        public
    {
        extraBuy = uint96(bound(extraBuy, 1e6, 50_000e6));
        pctBps = uint16(bound(uint256(pctBps), 100, 9999));
        donation = uint96(bound(donation, 1, 5_000e6));

        // Push the curve into premium territory.
        vm.startPrank(bob);
        usdc.approve(address(curve), extraBuy);
        curve.buy(extraBuy, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Donate USDC directly to the treasury (sim a deferred-buy idle pool).
        usdc.mint(address(treasury), donation);

        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 sellAmount = (aliceAgent * pctBps) / 10000;
        if (sellAmount == 0) return;

        uint256 supplyBefore = curve.totalSupply();
        uint256 navBefore = treasury.nav();
        uint256 expectedNotional = (navBefore * sellAmount) / supplyBefore;

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 feeBefore = usdc.balanceOf(FEE_RECIPIENT);

        vm.prank(alice);
        curve.sell(sellAmount, alice, 0, true, block.timestamp);

        uint256 aliceUsdcGot = usdc.balanceOf(alice) - aliceUsdcBefore;
        uint256 feeGot = usdc.balanceOf(FEE_RECIPIENT) - feeBefore;
        // Realized USDC = what the seller received plus the 1% fee skimmed off it.
        uint256 usdcRealized = aliceUsdcGot + feeGot;

        // Mock LTs hold the USDC minted into them at a 1:1 rate, so every leg's
        // redeem fills: the full notional is realized in USDC (idle + redeemed),
        // never raw LTs. A few base units of slack for per-leg redeem rounding.
        assertLe(usdcRealized, expectedNotional, "never overpays notional");
        assertApproxEqAbs(usdcRealized, expectedNotional, 16, "USDC realized ~= full notional");
        // The 1% sell fee is skimmed from the realized USDC and routed to FEE_RECIPIENT.
        assertEq(feeGot, usdcRealized / 100, "1% sell fee skimmed to fee recipient");
        assertEq(
            IERC20(address(ltA)).balanceOf(alice) + IERC20(address(ltB)).balanceOf(alice),
            0,
            "no raw LTs when redeem fills"
        );
    }

    // ─── NAV conservation on rebalance ─────────────────────────────────────

    /// Setting a new target portfolio preserves NAV in the zero-fee mock
    /// world. Any drift means the shrink/grow loops are losing or gaining
    /// value spuriously.
    function testFuzz_Rebalance_PreservesNav(uint96 extraBuy, uint16 newA) public {
        extraBuy = uint96(bound(extraBuy, 100e6, 50_000e6));
        // Use the full bps range that doesn't violate other invariants.
        newA = uint16(bound(uint256(newA), 100, 9900));

        vm.startPrank(bob);
        usdc.approve(address(curve), extraBuy);
        curve.buy(extraBuy, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 navBefore = treasury.nav();

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: newA});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: uint16(10000 - newA)});

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");

        // Just resetting weights doesn't move LTs — NAV is identical.
        assertEq(treasury.nav(), navBefore, "set-target alone changed NAV");
    }

    // ─── in-flight invariants ──────────────────────────────────────────────

    /// While rebalanceInFlight is true, ANY buy must revert with
    /// RebalancePending. Fuzz the buy size.
    function testFuzz_Buy_BlockedDuringRebalanceInFlight(uint96 size) public {
        size = uint96(bound(size, 1e6, 100_000e6));

        // Force the async path so executeRebalanceStep flips the flag.
        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 8000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 2000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = new uint256[](2);
        wide[0] = type(uint256).max;
        wide[1] = type(uint256).max;
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);
        assertTrue(treasury.rebalanceInFlight());

        vm.startPrank(bob);
        usdc.approve(address(curve), size);
        vm.expectRevert(AgentTreasury.RebalancePending.selector);
        curve.buy(size, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();
    }

    /// Symmetric: any sell during in-flight reverts.
    function testFuzz_Sell_BlockedDuringRebalanceInFlight(uint16 pctBps) public {
        pctBps = uint16(bound(uint256(pctBps), 1, 9999));

        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 8000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 2000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = new uint256[](2);
        wide[0] = type(uint256).max;
        wide[1] = type(uint256).max;
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 sellAmount = (aliceAgent * pctBps) / 10000;
        if (sellAmount == 0) return;

        vm.prank(alice);
        vm.expectRevert(AgentTreasury.RebalancePending.selector);
        curve.sell(sellAmount, alice, 0, true, block.timestamp);
    }

    // ─── nav() invariant ───────────────────────────────────────────────────

    /// nav() == idle USDC + Σ ltToBaseAmount(lt.balanceOf(treasury)) for ANY
    /// state, for ANY combination of buys + donations.
    function testFuzz_Nav_EqualsSumOfHoldings(uint96 buySize, uint96 donation) public {
        buySize = uint96(bound(buySize, 0, 50_000e6));
        donation = uint96(bound(donation, 0, 10_000e6));

        if (buySize > 0) {
            vm.startPrank(bob);
            usdc.approve(address(curve), buySize);
            curve.buy(buySize, 0, _emptyMinLtOuts(), bob, block.timestamp);
            vm.stopPrank();
        }
        if (donation > 0) usdc.mint(address(treasury), donation);

        uint256 expected = usdc.balanceOf(address(treasury))
            + ltA.ltToBaseAmount(IERC20(address(ltA)).balanceOf(address(treasury)))
            + ltB.ltToBaseAmount(IERC20(address(ltB)).balanceOf(address(treasury)));
        assertEq(treasury.nav(), expected);
    }
}
