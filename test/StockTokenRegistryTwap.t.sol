// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";
import {OracleLibrary} from "../src/libraries/OracleLibrary.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// TWAP valuation + anti-manipulation guards for StockTokenRegistry.
///
/// The tick→amount math is Uniswap's audited OracleLibrary/TickMath/FullMath,
/// vendored verbatim; these tests target the REGISTRY's own logic — pool wiring,
/// two-hop composition, the spot-vs-TWAP separation that defeats manipulation,
/// and the listing/history/window guards.
contract StockTokenRegistryTwapTest is Test {
    StockTokenRegistry internal registry;

    // Plain addresses — the registry never calls the tokens themselves, only the
    // pool stubs. Chosen so STABLE < WETH < TOKEN for deterministic ordering.
    address internal constant STABLE = address(0x1111111111111111111111111111111111111111);
    address internal constant WETH = address(0x2222222222222222222222222222222222222222);
    address internal constant TOKEN = address(0x3333333333333333333333333333333333333333);

    function setUp() public {
        vm.warp(2_000_000); // realistic timestamp so history math doesn't underflow
        registry = new StockTokenRegistry(address(this), STABLE);
    }

    function _directPool(int24 meanTick, uint128 liq) internal returns (MockUniswapV3Pool pool) {
        pool = new MockUniswapV3Pool(STABLE, TOKEN, 3000, liq);
        pool.setMeanTick(meanTick);
    }

    // --- absolute anchor: tick 0 ⇒ 1:1 raw-unit price ---------------------

    function test_tickZeroIsIdentity() public {
        MockUniswapV3Pool pool = _directPool(0, 1e18);
        registry.addToken(TOKEN, address(0), 3000, 0, address(pool), address(0));
        assertEq(registry.valueOf(TOKEN, 1e6), 1e6, "tick 0 must be identity on raw units");
        assertEq(registry.amountOf(TOKEN, 1e6), 1e6, "inverse at tick 0 is identity too");
    }

    // --- the point of TWAP: spot cannot move NAV --------------------------

    function test_spotManipulationDoesNotMoveValue() public {
        MockUniswapV3Pool pool = _directPool(1000, 1e18);
        registry.addToken(TOKEN, address(0), 3000, 0, address(pool), address(0));

        uint256 before = registry.valueOf(TOKEN, 1e18);
        // Attacker shoves the in-block spot price hard in both directions.
        pool.setSpotTick(500000);
        assertEq(registry.valueOf(TOKEN, 1e18), before, "spot up must not change NAV");
        pool.setSpotTick(-500000);
        assertEq(registry.valueOf(TOKEN, 1e18), before, "spot down must not change NAV");

        // Only a move in the *mean* (sustained over the window) changes NAV.
        pool.setMeanTick(2000);
        assertTrue(registry.valueOf(TOKEN, 1e18) != before, "mean tick move must change NAV");
    }

    // --- two-hop composition matches the sequential quote -----------------

    function test_twoHopCompositionMatchesLib() public {
        MockUniswapV3Pool poolIn = new MockUniswapV3Pool(STABLE, WETH, 100, 1e18); // USDG↔WETH
        MockUniswapV3Pool poolOut = new MockUniswapV3Pool(WETH, TOKEN, 3000, 1e18); // WETH↔TOKEN
        poolIn.setMeanTick(-2000);
        poolOut.setMeanTick(3500);
        registry.addToken(TOKEN, WETH, 100, 3000, address(poolIn), address(poolOut));

        uint256 amount = 5e17;
        // Expected: token → WETH via poolOut, then WETH → USDG via poolIn.
        uint256 wethLeg = OracleLibrary.getQuoteAtTick(3500, uint128(amount), TOKEN, WETH);
        uint256 expected = OracleLibrary.getQuoteAtTick(-2000, uint128(wethLeg), WETH, STABLE);
        assertEq(registry.valueOf(TOKEN, amount), expected, "two-hop valueOf must compose the two pool TWAPs");

        // Manipulating spot on either leg still moves nothing.
        poolIn.setSpotTick(400000);
        poolOut.setSpotTick(-400000);
        assertEq(registry.valueOf(TOKEN, amount), expected, "two-hop NAV immune to spot on both legs");
    }

    function test_amountOfRoundTrips() public {
        MockUniswapV3Pool poolIn = new MockUniswapV3Pool(STABLE, WETH, 100, 1e18);
        MockUniswapV3Pool poolOut = new MockUniswapV3Pool(WETH, TOKEN, 3000, 1e18);
        poolIn.setMeanTick(-1500);
        poolOut.setMeanTick(2200);
        registry.addToken(TOKEN, WETH, 100, 3000, address(poolIn), address(poolOut));

        uint256 tokenAmt = registry.amountOf(TOKEN, 1_000e6); // $1000 worth of TOKEN
        uint256 backToUsd = registry.valueOf(TOKEN, tokenAmt);
        // Round-trip through two hops accrues only rounding dust.
        assertApproxEqRel(backToUsd, 1_000e6, 1e12); // within 1e-6
    }

    // --- guards -----------------------------------------------------------

    function test_insufficientHistoryReverts() public {
        MockUniswapV3Pool pool = _directPool(0, 1e18);
        pool.setHistory(300); // < minTwapWindow (600)
        registry.addToken(TOKEN, address(0), 3000, 0, address(pool), address(0));

        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.InsufficientHistory.selector, address(pool), uint32(300)));
        registry.valueOf(TOKEN, 1e6);
    }

    function test_windowClampsToAvailableHistory() public {
        MockUniswapV3Pool pool = _directPool(1234, 1e18);
        registry.addToken(TOKEN, address(0), 3000, 0, address(pool), address(0));
        uint256 full = registry.valueOf(TOKEN, 1e18); // history 3600 ≥ twapWindow 1800

        // Shrink history below the target window but above the floor: still prices
        // (clamped), and since the mean tick is constant the value is unchanged.
        pool.setHistory(900);
        assertEq(registry.valueOf(TOKEN, 1e18), full, "clamped window on constant tick yields same value");
    }

    function test_poolMismatchRejectedAtListing() public {
        // Pool pairs the wrong tokens for a direct listing (WETH/TOKEN, not STABLE/TOKEN).
        MockUniswapV3Pool wrong = new MockUniswapV3Pool(WETH, TOKEN, 3000, 1e18);
        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.PoolMismatch.selector, address(wrong)));
        registry.addToken(TOKEN, address(0), 3000, 0, address(wrong), address(0));
    }

    function test_feeMismatchRejectedAtListing() public {
        MockUniswapV3Pool pool = new MockUniswapV3Pool(STABLE, TOKEN, 500, 1e18); // fee 500
        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.PoolMismatch.selector, address(pool)));
        registry.addToken(TOKEN, address(0), 3000, 0, address(pool), address(0)); // declares 3000
    }

    function test_minPoolLiquidityGate() public {
        registry.setMinPoolLiquidity(1_000_000);
        MockUniswapV3Pool thin = new MockUniswapV3Pool(STABLE, TOKEN, 3000, 500_000);
        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.InsufficientLiquidity.selector, address(thin), uint128(500_000)));
        registry.addToken(TOKEN, address(0), 3000, 0, address(thin), address(0));

        MockUniswapV3Pool deep = new MockUniswapV3Pool(STABLE, TOKEN, 3000, 2_000_000);
        registry.addToken(TOKEN, address(0), 3000, 0, address(deep), address(0)); // passes
        assertTrue(registry.tokenExists(TOKEN));
    }

    function test_windowSettersValidate() public {
        vm.expectRevert(StockTokenRegistry.InvalidWindow.selector);
        registry.setTwapWindow(0);
        vm.expectRevert(StockTokenRegistry.InvalidWindow.selector);
        registry.setTwapWindow(500); // < minTwapWindow 600
        vm.expectRevert(StockTokenRegistry.InvalidWindow.selector);
        registry.setMinTwapWindow(2000); // > twapWindow 1800

        registry.setTwapWindow(3600); // ok
        registry.setMinTwapWindow(1200); // ok now that window grew
        assertEq(registry.twapWindow(), 3600);
        assertEq(registry.minTwapWindow(), 1200);
    }

    function test_directRouteValidationRejectsStrayPoolOut() public {
        MockUniswapV3Pool pool = _directPool(0, 1e18);
        MockUniswapV3Pool stray = new MockUniswapV3Pool(WETH, TOKEN, 3000, 1e18);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.addToken(TOKEN, address(0), 3000, 0, address(pool), address(stray));
    }

    function test_notRegisteredReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.NotRegistered.selector, TOKEN));
        registry.valueOf(TOKEN, 1e6);
    }
}
