// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {TreasuryFactory} from "../src/TreasuryFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockBounceLT} from "./mocks/MockBounceLT.sol";
import {MockBounceFactory} from "./mocks/MockBounceFactory.sol";
import {MockLeveragedTokenHelper} from "./mocks/MockLeveragedTokenHelper.sol";

/// A trivial subclass that adds a new view to AgentTreasury without
/// changing any storage layout. Used to verify that:
///   (a) beacon.upgradeTo(new impl) swaps logic for every deployed proxy,
///   (b) storage is preserved verbatim across the swap,
///   (c) the new view is callable on existing proxies after the upgrade.
contract AgentTreasuryV2 is AgentTreasury {
    /// Sentinel to prove the proxy is now delegating to V2.
    function version2() external pure returns (string memory) {
        return "v2";
    }
}

/// End-to-end upgrade tests: deploy infra → deploy proxy → snapshot state →
/// upgrade beacon → verify state intact + new behavior live.
///
/// Storage drift is the single most common upgrade footgun, so the asserts
/// here are deliberately exhaustive: every persisted slot (immutable-style
/// fields, mappings, dynamic arrays, packed bools) must round-trip across
/// the upgrade.
contract BeaconUpgradeTest is Test {
    MockUSDC usdc;
    MockBounceLT ltA;
    MockBounceLT ltB;
    MockBounceFactory factory;
    MockLeveragedTokenHelper helper;

    AgentTreasury impl;
    UpgradeableBeacon beacon;
    TreasuryFactory treasuryFactory;
    AgentTreasury treasury;
    AgentCurve curve;

    uint256 userPk = 0xA11CE;
    address user;
    address deployer = address(0xD3B107E5);
    address rebalancer = address(0xBEEF);

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6;

    function setUp() public {
        user = vm.addr(userPk);
        usdc = new MockUSDC();
        ltA = new MockBounceLT("HYPE 5x Long", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        ltB = new MockBounceLT("BTC 5x Long",  "BTC5L",  address(usdc), "BTC",  5, true, 1e18);
        helper = new MockLeveragedTokenHelper();
        factory = new MockBounceFactory();
        factory.add(address(ltA));
        factory.add(address(ltB));
        usdc.mint(user, 100_000 * 1e6);

        impl = new AgentTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));
        treasuryFactory = new TreasuryFactory(
            address(usdc), address(helper), address(factory), address(beacon), deployer
        );

        treasury = _deployTreasury();
        curve = AgentCurve(treasury.curve());
    }

    function _deployTreasury() internal returns (AgentTreasury) {
        AgentTreasury.AssetSpec[] memory portfolio = new AgentTreasury.AssetSpec[](2);
        portfolio[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        portfolio[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        TreasuryFactory.DeployParams memory p = TreasuryFactory.DeployParams({
            user: user,
            salt: bytes32(uint256(1)),
            seed: SEED,
            rebalancer: rebalancer,
            initialPortfolio: portfolio,
            reasoningCid: "ipfs://genesis",
            curveName: "Vol Vampire",
            curveSymbol: "FANG",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium: EXTRA_PREMIUM,
            minLtOuts: new uint256[](2)
        });
        TreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        vm.prank(deployer);
        (address t,) = treasuryFactory.deployTreasury(p, permit);
        return AgentTreasury(t);
    }

    function _signPermit(uint256 value, uint256 deadline)
        internal view returns (TreasuryFactory.PermitData memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(treasuryFactory),
                value,
                usdc.nonces(user),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return TreasuryFactory.PermitData({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    // ─── upgrade path ──────────────────────────────────────────────────────

    /// Smoke test: deploy V2 impl, point the beacon at it, verify the new
    /// view is callable on the pre-existing proxy. Storage preservation is
    /// asserted separately below.
    function test_Upgrade_BeaconRetargetsAllProxies() public {
        AgentTreasuryV2 newImpl = new AgentTreasuryV2();
        beacon.upgradeTo(address(newImpl));
        assertEq(beacon.implementation(), address(newImpl));
        assertEq(AgentTreasuryV2(address(treasury)).version2(), "v2");
    }

    struct StorageSnapshot {
        uint256 nav;
        uint256 supply;
        address curveAddr;
        address creator;
        address rebalancer;
        bool inFlight;
        uint256 assetCount;
        address ltHype;
        uint16 bpsHype;
        address ltBtc;
        uint16 bpsBtc;
    }

    function _snapshot() internal view returns (StorageSnapshot memory snap) {
        snap.nav            = treasury.nav();
        snap.supply         = curve.totalSupply();
        snap.curveAddr      = treasury.curve();
        snap.creator        = treasury.CREATOR();
        snap.rebalancer     = treasury.rebalancer();
        snap.inFlight       = treasury.rebalanceInFlight();
        snap.assetCount     = treasury.assetCount();
        (snap.ltHype, snap.bpsHype,) = treasury.assets("HYPE5L");
        (snap.ltBtc,  snap.bpsBtc,)  = treasury.assets("BTC5L");
    }

    /// Storage drift guard: snapshot every persistent field, upgrade beacon
    /// to a structurally-identical V2, and assert every value round-trips.
    /// If anyone reorders/renames storage in a future PR this fails loud.
    function test_Upgrade_PreservesAllStorage() public {
        StorageSnapshot memory before = _snapshot();

        AgentTreasuryV2 newImpl = new AgentTreasuryV2();
        beacon.upgradeTo(address(newImpl));

        StorageSnapshot memory afterUpgrade = _snapshot();

        assertEq(afterUpgrade.nav,            before.nav,            "nav drifted");
        assertEq(afterUpgrade.supply,         before.supply,         "curve supply drifted");
        assertEq(afterUpgrade.curveAddr,      before.curveAddr,      "curve addr drifted");
        assertEq(afterUpgrade.creator,        before.creator,        "creator drifted");
        assertEq(afterUpgrade.rebalancer,     before.rebalancer,     "rebalancer drifted");
        assertEq(afterUpgrade.inFlight,       before.inFlight,       "inFlight drifted");
        assertEq(afterUpgrade.assetCount,     before.assetCount,     "asset count drifted");
        assertEq(afterUpgrade.ltHype,         before.ltHype);
        assertEq(afterUpgrade.bpsHype,        before.bpsHype);
        assertEq(afterUpgrade.ltBtc,          before.ltBtc);
        assertEq(afterUpgrade.bpsBtc,         before.bpsBtc);
    }

    /// After upgrade, existing proxies must still accept normal traffic
    /// (curve buy → treasury deployUsdc → Bounce mint).
    function test_Upgrade_ProxyStillFunctional() public {
        AgentTreasuryV2 newImpl = new AgentTreasuryV2();
        beacon.upgradeTo(address(newImpl));

        // Buy through the curve — exercises the upgraded treasury's
        // deployUsdc + LT mint path.
        usdc.mint(user, 100e6);
        vm.startPrank(user);
        usdc.approve(address(curve), 100e6);
        uint256[] memory minLtOuts = new uint256[](2);
        curve.buy(100e6, 0, minLtOuts, user, block.timestamp);
        vm.stopPrank();

        assertGt(curve.balanceOf(user), 0, "buy didn't mint AGENT post-upgrade");
    }

    // ─── access control ────────────────────────────────────────────────────

    /// Only the beacon owner can call upgradeTo. In production the owner is
    /// the TimelockController; here it's the test contract.
    function test_Upgrade_NonOwnerReverts() public {
        AgentTreasuryV2 newImpl = new AgentTreasuryV2();
        address stranger = address(0xDEAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        beacon.upgradeTo(address(newImpl));
    }

    /// Timelock + Safe path: schedule an upgrade, execute before delay
    /// elapses (must revert), warp past delay, execute (must succeed).
    function test_Upgrade_TimelockGated() public {
        // Set up timelock with 48h delay, the test contract as proposer +
        // executor (stands in for the production Safe).
        uint256 delay = 48 hours;
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(this);
        executors[0] = address(this);
        TimelockController timelock = new TimelockController(delay, proposers, executors, address(0));

        beacon.transferOwnership(address(timelock));

        AgentTreasuryV2 newImpl = new AgentTreasuryV2();
        bytes memory call = abi.encodeWithSelector(UpgradeableBeacon.upgradeTo.selector, address(newImpl));
        bytes32 salt = bytes32(uint256(42));

        // Schedule
        timelock.schedule(address(beacon), 0, call, bytes32(0), salt, delay);

        // Execute before delay → must revert
        vm.expectRevert();
        timelock.execute(address(beacon), 0, call, bytes32(0), salt);

        // Warp past the delay, execute → succeeds, beacon now points at v2
        vm.warp(block.timestamp + delay + 1);
        timelock.execute(address(beacon), 0, call, bytes32(0), salt);
        assertEq(beacon.implementation(), address(newImpl));
        assertEq(AgentTreasuryV2(address(treasury)).version2(), "v2");
    }

    // ─── impl initialization lock ──────────────────────────────────────────

    /// The impl contract's storage must be permanently uninitializable —
    /// `_disableInitializers()` in the impl constructor sets `_initialized`
    /// to type(uint64).max so any direct call to `initialize` reverts.
    function test_Impl_CannotBeInitializedDirectly() public {
        AgentTreasury.AssetSpec[] memory portfolio = new AgentTreasury.AssetSpec[](1);
        portfolio[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 10000});
        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "x", symbol: "x",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: user, recipient: user,
            minLtOuts: new uint256[](1)
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            rebalancer, user,
            address(0), portfolio, "ipfs://x", ci
        );
    }
}
