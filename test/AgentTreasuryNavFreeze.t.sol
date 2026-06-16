// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockBounceLT} from "./mocks/MockBounceLT.sol";
import {MockBounceFactory} from "./mocks/MockBounceFactory.sol";
import {MockLeveragedTokenHelper} from "./mocks/MockLeveragedTokenHelper.sol";
import {MockTreasuryFactory} from "./mocks/MockTreasuryFactory.sol";

/// Lives in its own contract (not AgentTreasury.t.sol) because that test
/// contract is already near solc's via_ir code-size limit ("Tag too large for
/// reserved space"); adding here keeps both compiling.
contract AgentTreasuryNavFreezeTest is Test {
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

    function setUp() public {
        usdc = new MockUSDC();
        ltA = new MockBounceLT("HYPE 5x Long", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        ltB = new MockBounceLT("BTC 5x Long",  "BTC5L",  address(usdc), "BTC",  5, true, 1e18);
        helper = new MockLeveragedTokenHelper();

        factory = new MockBounceFactory();
        feeRegistry = new MockTreasuryFactory(address(usdc), address(helper), address(factory));
        factory.add(address(ltA));
        factory.add(address(ltB));

        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob,   100_000 * 1e6);

        AgentTreasury impl = new AgentTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));

        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "Vol Vampire",
            symbol: "FANG",
            premiumCapSupply: 30_000 * 1e18,
            extraPremium: 2e18,
            usdcSeed: 1_000 * 1e6,
            seeder: alice,
            recipient: alice,
            minLtOuts: new uint256[](2)
        });

        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                rebalancer, creator,
                address(feeRegistry), _portfolio2(5000, 5000), "ipfs://genesis", ci
            )
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(alice);
        usdc.approve(predicted, ci.usdcSeed);
        treasury = AgentTreasury(address(new BeaconProxy(address(beacon), initData)));
        require(address(treasury) == predicted, "predicted proxy address mismatch");
        curve = AgentCurve(treasury.curve());
    }

    // Portfolio rotation must not depend on pricing. If a held leg becomes
    // unpriceable (HyperCore delisting → ltToBaseAmount reverts → nav() reverts),
    // setTargetPortfolio must still succeed so the rebalancer can rotate the bad
    // leg out. Regression for the nav()-in-emit freeze: the emit no longer calls
    // nav(), so rotation survives even while nav()/buy/sell are frozen.
    function test_SetTargetPortfolio_SucceedsWhenAHeldLegIsUnpriceable() public {
        // Seed holdings in both legs while healthy.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, new uint256[](2), bob, block.timestamp);
        vm.stopPrank();

        // HYPE5L's underlying delists: its pricing view now reverts.
        ltA.setLtViewReverts(true);

        // Precondition: nav() (and thus buy/sell) is frozen by the bad leg.
        vm.expectRevert(bytes("delisted-view"));
        treasury.nav();

        // Rotation still works: drop the unpriceable HYPE5L, go 100% BTC5L.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("BTC5L", address(ltB)), "ipfs://rotate-out-delisted");

        (, uint16 bpsA,) = treasury.assets("HYPE5L");
        (, uint16 bpsB,) = treasury.assets("BTC5L");
        assertEq(bpsA, 0, "delisted leg rotated to zero weight");
        assertEq(bpsB, 10000, "surviving leg now full weight");
    }

    function _portfolio2(uint16 bpsA, uint16 bpsB)
        internal view returns (AgentTreasury.AssetSpec[] memory p)
    {
        p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: bpsA});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: bpsB});
    }

    function _single(string memory sym, address lt)
        internal pure returns (AgentTreasury.AssetSpec[] memory p)
    {
        p = new AgentTreasury.AssetSpec[](1);
        p[0] = AgentTreasury.AssetSpec({symbol: sym, lt: lt, bps: 10000});
    }
}
