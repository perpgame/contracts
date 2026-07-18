// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockStockTreasuryFactory} from "./mocks/MockStockTreasuryFactory.sol";

/// NAV vs the registry marks: nav() must track marks live, must revert (not
/// trade at a stale mark) once a leg becomes unpriceable, and portfolio
/// rotation must keep working while nav() is frozen so the rebalancer can
/// rotate a bad leg out. On the real registry an "unpriceable" leg is one with
/// too little TWAP history; here we model it with MockRegistry.setFrozen. Lives
/// in its own contract (not StockTreasury.t.sol) because that test contract is
/// already near solc's via_ir code-size limit.
contract StockTreasuryNavFreezeTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA;
    MockStockToken tokenB;
    MockRegistry registry;
    MockSwapRouter router;
    MockStockTreasuryFactory feeRegistry;
    StockTreasury treasury;
    AgentCurve curve;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");

        registry = new MockRegistry(address(usdc)); // both tokens default to a $1 mark
        registry.addToken(address(tokenA), address(0), 3000, 0);
        registry.addToken(address(tokenB), address(0), 3000, 0);
        registry.setMinTradeStable(10e6);

        router = new MockSwapRouter(address(usdc), address(registry));
        usdc.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        feeRegistry = new MockStockTreasuryFactory(address(usdc), address(router), address(registry));

        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob,   100_000 * 1e6);

        StockTreasury impl = new StockTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));

        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "Vol Vampire",
            symbol: "FANG",
            premiumCapSupply: 30_000 * 1e18,
            extraPremium: 2e18,
            stableSeed: 1_000 * 1e6,
            seeder: alice,
            recipient: alice,
            minTokenOuts: new uint256[](2)
        });

        bytes memory initData = abi.encodeCall(
            StockTreasury.initialize,
            (
                rebalancer, creator,
                address(feeRegistry), _portfolio2(5000, 5000), "ipfs://genesis", ci
            )
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, ci.stableSeed);
        treasury = StockTreasury(address(new BeaconProxy(address(beacon), initData)));
        require(address(treasury) == predicted, "predicted proxy address mismatch");
        curve = AgentCurve(treasury.curve());
    }

    // nav() marks every leg at the LIVE mark: when a mark moves, nav moves in
    // lockstep — no frozen internal rate.
    function test_Nav_TracksMark() public {
        // Seed: 500 A + 500 B tokens, both at $1 → nav $1000.
        assertEq(treasury.nav(), 1000 * 1e6, "nav at the $1 marks");

        // A doubles, B halves.
        registry.setMark(address(tokenA), 2e6);   // $2
        registry.setMark(address(tokenB), 0.5e6); // $0.50

        // nav = 500 tokens × $2 + 500 tokens × $0.50 = $1250.
        assertEq(treasury.nav(), 1250 * 1e6, "nav re-marks at the new marks");

        // And back: restoring the marks restores nav exactly.
        registry.setMark(address(tokenA), 1e6);
        registry.setMark(address(tokenB), 1e6);
        assertEq(treasury.nav(), 1000 * 1e6, "nav returns with the marks");
    }

    // An unpriceable leg makes the registry refuse to value it: nav() reverts
    // instead of valuing the basket at a bad mark.
    function test_Nav_RevertsWhenLegUnpriceable() public {
        registry.setFrozen(address(tokenA), true);

        vm.expectRevert(bytes("MockRegistry: stale"));
        treasury.nav();

        // Un-freezing restores it.
        registry.setFrozen(address(tokenA), false);
        assertEq(treasury.nav(), 1000 * 1e6, "nav works again once priceable");
    }

    // Portfolio rotation must not depend on pricing. If a held leg becomes
    // unpriceable (valueOf reverts → nav() reverts), setTargetPortfolio must
    // still succeed so the rebalancer can rotate the bad leg out while
    // nav()/buy/sell are frozen.
    function test_SetTargetPortfolio_SucceedsWhenAHeldLegIsUnpriceable() public {
        // Seed holdings in both legs while healthy.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        // AAPL becomes unpriceable (corporate action / delisting / dead pool).
        // B stays priceable so only A is the frozen leg.
        registry.setFrozen(address(tokenA), true);

        // Precondition: nav() (and thus buy/sell) is frozen by the bad leg.
        vm.expectRevert(bytes("MockRegistry: stale"));
        treasury.nav();

        // Rotation still works: drop the unpriceable AAPL, go 100% TSLA.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("TSLA", address(tokenB)), "ipfs://rotate-out-frozen");

        (, uint16 bpsA,) = treasury.assets("AAPL");
        (, uint16 bpsB,) = treasury.assets("TSLA");
        assertEq(bpsA, 0, "frozen leg rotated to zero weight");
        assertEq(bpsB, 10000, "surviving leg now full weight");
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
}
