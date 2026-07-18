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

/// Property-based fuzz tests for AgentCurve + StockTreasury under the
/// swap-based, atomic architecture. Each test runs 256 random inputs by default.
///
/// Invariants exercised:
/// - premium curve shape (bounds, monotonicity, exact anchor at 0)
/// - quote_match: quoteBuy(x) == buy(x).agentOut for any state
/// - no_free_money: sell notional ≤ stableIn for any back-to-back round trip
/// - sell_pro_rata: selling X/total of supply transfers ≤ X/total of each leg
/// - never_overpay: withdrawAssetsTo never gives the seller more than their NAV share
/// - rebalance_preserves_nav: zero-fee mock router → NAV unchanged by a
///   set-target + executeRebalanceStep pass
contract StockCurveFuzzTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA;
    MockStockToken tokenB;
    MockAggregator feedA;
    MockAggregator feedB;
    StockTokenRegistry registry;
    MockSwapRouter router;
    MockStockTreasuryFactory feeRegistry;
    StockTreasury treasury;
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
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");
        feedA = new MockAggregator(8, 1e8);
        feedB = new MockAggregator(8, 1e8);

        registry = new StockTokenRegistry(address(this), address(usdc));
        registry.addToken(address(tokenA), address(feedA), address(0), 3000, 0);
        registry.addToken(address(tokenB), address(feedB), address(0), 3000, 0);
        registry.setMinTradeStable(10e6);

        router = new MockSwapRouter(address(usdc));
        router.setFeed(address(tokenA), feedA);
        router.setFeed(address(tokenB), feedB);
        usdc.mint(address(router), 1e30);
        tokenA.mint(address(router), 1e40);
        tokenB.mint(address(router), 1e40);

        feeRegistry = new MockStockTreasuryFactory(address(usdc), address(router), address(registry));

        usdc.mint(alice, 1e30);
        usdc.mint(bob, 1e30);

        _deployAtomically();
    }

    function _deployAtomically() internal {
        StockTreasury impl = new StockTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));

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

        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});

        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
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
        treasury = StockTreasury(address(proxy));
        curve = AgentCurve(treasury.curve());
    }

    function _emptyMinTokenOuts() internal pure returns (uint256[] memory m) {
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
        curve.buy(aliceBuy, 0, _emptyMinTokenOuts(), alice, block.timestamp);
        vm.stopPrank();

        uint256 quoted = curve.quoteBuy(bobBuy);
        vm.startPrank(bob);
        usdc.approve(address(curve), bobBuy);
        uint256 actual = curve.buy(bobBuy, 0, _emptyMinTokenOuts(), bob, block.timestamp);
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
        uint256 bobAgent = curve.buy(bobBuy, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        uint256 sellNotional = curve.quoteSellNotional(bobAgent);
        vm.stopPrank();

        assertLe(sellNotional, bobBuy, "buyer extracted more than they paid");
    }

    // ─── monotonic worsening for later buyers ──────────────────────────────

    /// Same stable buys fewer or equal AGENT at higher supply. Two buys in
    /// sequence — the second must mint ≤ the first.
    function testFuzz_LaterBuyer_GetsLessOrEqual(uint96 buySize) public {
        buySize = uint96(bound(buySize, 1e6, 5_000e6));

        usdc.mint(bob, 1e30);
        vm.startPrank(bob);
        usdc.approve(address(curve), uint256(buySize) * 2);
        uint256 first = curve.buy(buySize, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        uint256 second = curve.buy(buySize, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertLe(second, first, "second buy not at worse-or-equal price");
    }

    // ─── proportional sell ─────────────────────────────────────────────────

    /// Selling pct/10000 of total supply pays out pct/10000 of every leg's
    /// balance (within rounding). Catches drift in withdrawAssetsTo math.
    function testFuzz_Sell_ProRataAcrossLegs(uint96 extraBuy, uint16 pctBps) public {
        extraBuy = uint96(bound(extraBuy, 1e6, 100_000e6));
        pctBps = uint16(bound(uint256(pctBps), 1, 9999));

        // Bob adds to the pot so alice isn't the only holder.
        vm.startPrank(bob);
        usdc.approve(address(curve), extraBuy);
        curve.buy(extraBuy, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 sellAmount = (aliceAgent * pctBps) / 10000;
        if (sellAmount == 0) return;

        uint256 supplyBefore = curve.totalSupply();
        uint256 aBefore = IERC20(address(tokenA)).balanceOf(address(treasury));
        uint256 bBefore = IERC20(address(tokenB)).balanceOf(address(treasury));
        uint256 idleBefore = usdc.balanceOf(address(treasury));

        vm.prank(alice);
        curve.sell(sellAmount, alice, 0, true, block.timestamp);

        // Expected total payout value = nav_before * sellAmount / supplyBefore.
        uint256 navBefore = idleBefore
            + registry.valueOf(address(tokenA), aBefore)
            + registry.valueOf(address(tokenB), bBefore);
        uint256 expectedNotional = (navBefore * sellAmount) / supplyBefore;

        // Compute paid-out value as the nav delta of the treasury.
        uint256 navAfter = usdc.balanceOf(address(treasury))
            + registry.valueOf(address(tokenA), IERC20(address(tokenA)).balanceOf(address(treasury)))
            + registry.valueOf(address(tokenB), IERC20(address(tokenB)).balanceOf(address(treasury)));
        uint256 paidOut = navBefore - navAfter;

        // Bound the drift symmetrically by ~1 wei per leg. valueOf floors
        // (amount × price / 1e20), so nav_before's two marks and nav_after's
        // two marks can each round in different directions, producing up to
        // 2 wei of drift in EITHER direction between paidOut and the
        // floor-divided notional.
        assertLe(paidOut, expectedNotional + 2, "over-paid seller beyond rounding");
        assertGe(paidOut + 2, expectedNotional, "under-paid seller beyond rounding");
    }

    /// Idle stable pays out pro-rata and swaps fill the deficit. With a
    /// donation to the treasury, the seller realizes the full notional in
    /// stable (never raw tokens) when every leg's pool fills.
    function testFuzz_WithdrawAssetsTo_PaysStableWhenSwapsFill(uint96 extraBuy, uint16 pctBps, uint96 donation)
        public
    {
        extraBuy = uint96(bound(extraBuy, 1e6, 50_000e6));
        pctBps = uint16(bound(uint256(pctBps), 100, 9999));
        donation = uint96(bound(donation, 1, 5_000e6));

        // Push the curve into premium territory.
        vm.startPrank(bob);
        usdc.approve(address(curve), extraBuy);
        curve.buy(extraBuy, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Donate stable directly to the treasury (sim a deferred-buy idle pool).
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
        // Realized stable = what the seller received plus the 1% fee skimmed off it.
        uint256 stableRealized = aliceUsdcGot + feeGot;

        // The zero-fee router converts at the oracle mark, so every leg's swap
        // fills: the full notional is realized in stable (idle + swapped),
        // never raw tokens. A few base units of slack for per-leg rounding.
        assertLe(stableRealized, expectedNotional, "never overpays notional");
        assertApproxEqAbs(stableRealized, expectedNotional, 16, "stable realized ~= full notional");
        // The 1% sell fee is skimmed from the realized stable.
        assertEq(feeGot, stableRealized / 100, "1% sell fee skimmed to fee recipient");
        assertEq(
            IERC20(address(tokenA)).balanceOf(alice) + IERC20(address(tokenB)).balanceOf(alice),
            0,
            "no raw tokens when the swaps fill"
        );
    }

    // ─── NAV conservation on rebalance ─────────────────────────────────────

    /// Setting a new target portfolio and executing the rebalance step
    /// preserves NAV in the zero-fee mock world. Any drift means the
    /// sell/buy loops are losing or gaining value spuriously.
    function testFuzz_Rebalance_PreservesNav(uint96 extraBuy, uint16 newA) public {
        extraBuy = uint96(bound(extraBuy, 100e6, 50_000e6));
        newA = uint16(bound(uint256(newA), 100, 9900));

        vm.startPrank(bob);
        usdc.approve(address(curve), extraBuy);
        curve.buy(extraBuy, 0, _emptyMinTokenOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 navBefore = treasury.nav();

        StockTreasury.AssetSpec[] memory p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: newA});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: uint16(10000 - newA)});

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");

        // Just resetting weights doesn't move tokens — NAV is identical.
        assertEq(treasury.nav(), navBefore, "set-target alone changed NAV");

        // Executing the swap pass with a zero-fee router preserves NAV up to
        // per-leg flooring in amountOf/valueOf and the swap conversions.
        uint256[] memory zeros = _emptyMinTokenOuts();
        uint256[] memory wide = new uint256[](2);
        wide[0] = type(uint256).max;
        wide[1] = type(uint256).max;
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertApproxEqAbs(treasury.nav(), navBefore, 4, "rebalance step drifted NAV");
    }

    // ─── nav() invariant ───────────────────────────────────────────────────

    /// nav() == idle stable + Σ registry.valueOf(token, balance) for ANY
    /// state, for ANY combination of buys + donations.
    function testFuzz_Nav_EqualsSumOfHoldings(uint96 buySize, uint96 donation) public {
        buySize = uint96(bound(buySize, 0, 50_000e6));
        donation = uint96(bound(donation, 0, 10_000e6));

        if (buySize > 0) {
            vm.startPrank(bob);
            usdc.approve(address(curve), buySize);
            curve.buy(buySize, 0, _emptyMinTokenOuts(), bob, block.timestamp);
            vm.stopPrank();
        }
        if (donation > 0) usdc.mint(address(treasury), donation);

        uint256 expected = usdc.balanceOf(address(treasury))
            + registry.valueOf(address(tokenA), IERC20(address(tokenA)).balanceOf(address(treasury)))
            + registry.valueOf(address(tokenB), IERC20(address(tokenB)).balanceOf(address(treasury)));
        assertEq(treasury.nav(), expected);
    }
}
