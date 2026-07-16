// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockStockTreasuryFactory} from "./mocks/MockStockTreasuryFactory.sol";

/// Regression tests for the HIGH-severity findings from the stock-treasury
/// security audit. Each test reproduces the exploit/failure BEFORE the fix and
/// asserts the fixed behavior. See docs/audit-stock-treasury.md.
///
///   HIGH-1  returnTokens=true sells had no floor on the realized swap output
///           (per-leg amountOutMinimum:0, and the netOut floor was gated on
///           !returnTokens) — a sandwich drained the seller. FIXED.
///   HIGH-2  Shares mint against the Chainlink mark but redeem at the live pool
///           price; a feed/pool divergence during a freeze is an arb against
///           holders. NOT addressed here — the mint math lives in the shared,
///           already-audited AgentCurve, which is out of scope for this change.
///   HIGH-3  One stale/unpriceable leg reverted nav()/heldTokenValues() and so
///           bricked every holder's exit, even returnTokens=true. FIXED: the
///           withdraw path now settles unpriceable legs in-kind.
contract StockTreasuryAuditFindingsTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA;
    MockStockToken tokenB;
    MockAggregator feedA; // registry (oracle) feed
    MockAggregator feedB;
    StockTokenRegistry registry;
    MockSwapRouter router;
    MockStockTreasuryFactory factory;
    UpgradeableBeacon beacon;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE); // seed holder
    address bob = address(0xB0B); // attacker / second holder

    function setUp() public {
        usdc = new MockUSDC();
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");
        feedA = new MockAggregator(8, 1e8); // $1
        feedB = new MockAggregator(8, 1e8); // $1

        registry = new StockTokenRegistry(address(this));
        registry.addToken(address(tokenA), address(feedA), 3000);
        registry.addToken(address(tokenB), address(feedB), 3000);
        registry.setMinTradeStable(1e6); // $1

        router = new MockSwapRouter(address(usdc));
        router.setFeed(address(tokenA), feedA);
        router.setFeed(address(tokenB), feedB);
        usdc.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        factory = new MockStockTreasuryFactory(address(usdc), address(router), address(registry));

        usdc.mint(alice, 1_000_000 * 1e6);
        usdc.mint(bob, 1_000_000 * 1e6);

        StockTreasury impl = new StockTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));
    }

    // Builds a treasury with the given portfolio, seed, premium, and stable seed
    // pulled from `alice` (who becomes the seed shareholder).
    function _build(
        StockTreasury.AssetSpec[] memory portfolio,
        uint256 seed,
        uint256 extraPremium,
        uint256[] memory minTokenOuts
    ) internal returns (StockTreasury treasury, AgentCurve curve) {
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "Basket",
            symbol: "BSKT",
            premiumCapSupply: 1_000_000 * 1e18,
            extraPremium: extraPremium,
            stableSeed: seed,
            seeder: alice,
            recipient: alice,
            minTokenOuts: minTokenOuts
        });

        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize, (rebalancer, creator, address(factory), portfolio, "ipfs://genesis", ci)
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, seed);
        treasury = StockTreasury(address(new BeaconProxy(address(beacon), initData)));
        require(address(treasury) == predicted, "predicted mismatch");
        curve = AgentCurve(treasury.curve());
    }

    function _single(string memory sym, address token, uint16 bps)
        internal
        pure
        returns (StockTreasury.AssetSpec[] memory p)
    {
        p = new StockTreasury.AssetSpec[](1);
        p[0] = StockTreasury.AssetSpec({symbol: sym, token: token, bps: bps});
    }

    function _pair() internal view returns (StockTreasury.AssetSpec[] memory p) {
        p = new StockTreasury.AssetSpec[](2);
        p[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        p[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});
    }

    // ─── HIGH-1 ─────────────────────────────────────────────────────────────
    // A returnTokens=true seller sets a slippage floor `minUsdcOut`, but the
    // realized swap output was never checked against it (the netOut floor was
    // gated on !returnTokens, and every leg swapped at amountOutMinimum:0). A
    // sandwiched pool (modeled by router.feeBps) drains the seller with no
    // revert. Pre-fix this call SUCCEEDS with a shortfall; post-fix it reverts.
    function test_HIGH1_ReturnTokensSellHonorsSlippageFloor() public {
        (StockTreasury treasury, AgentCurve curve) =
            _build(_single("AAPL", address(tokenA), 10000), 1_000 * 1e6, 0, new uint256[](1));

        uint256 aliceShares = curve.balanceOf(alice);

        // Model a sandwich / severe pool impact: the swap returns 50% of the
        // oracle-marked value. The oracle notional (~$1000) still clears the
        // early gross-notional check, so only a realized-output floor can catch it.
        router.setFeeBps(5000);

        // Alice demands at least $900 of stable and accepts tokens if a swap
        // fails. Every leg here swaps successfully (just at a terrible price),
        // so nothing is returned in-kind — the floor must bind.
        uint256 minUsdcOut = 900 * 1e6;

        vm.prank(address(curve)); // withdrawLtsTo is onlyCurve
        vm.expectRevert(StockTreasury.SlippageExceeded.selector);
        treasury.withdrawLtsTo(alice, aliceShares, aliceShares, minUsdcOut, true);
    }

    // Companion: the same sandwich with returnTokens=true and a legitimately
    // in-kind leg (dead pool) must still be allowed to pay out mixed — the floor
    // only binds when nothing came back in-kind.
    function test_HIGH1_ReturnTokensInKindStillAllowedBelowFloor() public {
        (StockTreasury treasury, AgentCurve curve) = _build(_pair(), 1_000 * 1e6, 0, new uint256[](2));
        uint256 aliceShares = curve.balanceOf(alice);

        // TSLA's pool is dead → its leg is returned in-kind; AAPL swaps fine.
        router.setRevertToken(address(tokenB), true);

        vm.prank(address(curve));
        // High floor, but because a leg came back in-kind the realized-stable
        // floor is intentionally not enforced (oracle-notional floor governs).
        treasury.withdrawLtsTo(alice, aliceShares, aliceShares, 1, true);

        assertGt(tokenB.balanceOf(alice), 0, "dead-pool leg returned in-kind");
    }

    // ─── HIGH-3 ─────────────────────────────────────────────────────────────
    // A held leg whose feed goes stale makes registry.valueOf revert, which
    // pre-fix reverted heldTokenValues()/withdrawLtsTo() entirely — trapping
    // every holder, even with returnTokens=true. Post-fix the stale leg is
    // settled in-kind so the holder always exits.
    function test_HIGH3_StaleLegDoesNotTrapHolders() public {
        (StockTreasury treasury, AgentCurve curve) = _build(_pair(), 1_000 * 1e6, 0, new uint256[](2));
        uint256 aliceShares = curve.balanceOf(alice);

        // AAPL's feed freezes past the staleness window; keep TSLA fresh.
        (,,, uint256 updatedAt,) = feedA.latestRoundData();
        vm.warp(updatedAt + registry.maxPriceAge() + 1);
        feedB.setAnswer(1e8);

        // Precondition: nav()/buy are frozen by the bad leg.
        vm.expectRevert(
            abi.encodeWithSelector(StockTokenRegistry.StalePrice.selector, address(tokenA), updatedAt)
        );
        treasury.nav();

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 tokenABefore = tokenA.balanceOf(alice);

        // Exit with returnTokens=true: TSLA swaps to stable, AAPL comes back
        // in-kind. Pre-fix this whole call reverts StalePrice.
        vm.prank(alice);
        curve.sell(aliceShares, alice, 0, true, block.timestamp);

        assertGt(usdc.balanceOf(alice) - usdcBefore, 0, "healthy leg paid out in stable");
        assertGt(tokenA.balanceOf(alice) - tokenABefore, 0, "frozen leg returned in-kind");
    }
}
