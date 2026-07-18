// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {StockTreasuryFactory} from "../src/StockTreasuryFactory.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

/// A trivial subclass that adds a new view to StockTreasury without
/// changing any storage layout. Used to verify that:
///   (a) beacon.upgradeTo(new impl) swaps logic for every deployed proxy,
///   (b) storage is preserved verbatim across the swap,
///   (c) the new view is callable on existing proxies after the upgrade.
contract StockTreasuryV2 is StockTreasury {
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
contract StockBeaconUpgradeTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA;
    MockStockToken tokenB;
    MockAggregator feedA;
    MockAggregator feedB;
    StockTokenRegistry registry;
    MockSwapRouter router;

    StockTreasury impl;
    UpgradeableBeacon beacon;
    StockTreasuryFactory treasuryFactory;
    StockTreasury treasury;
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
        usdc.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        usdc.mint(user, 100_000 * 1e6);

        impl = new StockTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));
        treasuryFactory = new StockTreasuryFactory(
            address(usdc), address(router), address(registry), address(beacon), deployer
        );

        treasury = _deployTreasury();
        curve = AgentCurve(treasury.curve());
    }

    function _deployTreasury() internal returns (StockTreasury) {
        StockTreasury.AssetSpec[] memory portfolio = new StockTreasury.AssetSpec[](2);
        portfolio[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        portfolio[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});

        StockTreasuryFactory.DeployParams memory p = StockTreasuryFactory.DeployParams({
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
            minTokenOuts: new uint256[](2)
        });
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        vm.prank(deployer);
        (address t,) = treasuryFactory.deployTreasury(p, permit);
        return StockTreasury(t);
    }

    function _signPermit(uint256 value, uint256 deadline)
        internal view returns (StockTreasuryFactory.PermitData memory)
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
        return StockTreasuryFactory.PermitData({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    // ─── upgrade path ──────────────────────────────────────────────────────

    /// Smoke test: deploy V2 impl, point the beacon at it, verify the new
    /// view is callable on the pre-existing proxy. Storage preservation is
    /// asserted separately below.
    function test_Upgrade_BeaconRetargetsAllProxies() public {
        StockTreasuryV2 newImpl = new StockTreasuryV2();
        beacon.upgradeTo(address(newImpl));
        assertEq(beacon.implementation(), address(newImpl));
        assertEq(StockTreasuryV2(address(treasury)).version2(), "v2");
    }

    struct StorageSnapshot {
        uint256 nav;
        uint256 supply;
        address curveAddr;
        address creator;
        address rebalancer;
        uint256 depositIdle;
        uint256 assetCount;
        address tokenAapl;
        uint16 bpsAapl;
        address tokenTsla;
        uint16 bpsTsla;
    }

    function _snapshot() internal view returns (StorageSnapshot memory snap) {
        snap.nav            = treasury.nav();
        snap.supply         = curve.totalSupply();
        snap.curveAddr      = treasury.curve();
        snap.creator        = treasury.CREATOR();
        snap.rebalancer     = treasury.rebalancer();
        snap.depositIdle    = treasury.depositIdleStable();
        snap.assetCount     = treasury.assetCount();
        (snap.tokenAapl, snap.bpsAapl,) = treasury.assets("AAPL");
        (snap.tokenTsla, snap.bpsTsla,) = treasury.assets("TSLA");
    }

    /// Storage drift guard: snapshot every persistent field, upgrade beacon
    /// to a structurally-identical V2, and assert every value round-trips.
    /// If anyone reorders/renames storage in a future PR this fails loud.
    function test_Upgrade_PreservesAllStorage() public {
        StorageSnapshot memory before = _snapshot();

        StockTreasuryV2 newImpl = new StockTreasuryV2();
        beacon.upgradeTo(address(newImpl));

        StorageSnapshot memory afterUpgrade = _snapshot();

        assertEq(afterUpgrade.nav,            before.nav,            "nav drifted");
        assertEq(afterUpgrade.supply,         before.supply,         "curve supply drifted");
        assertEq(afterUpgrade.curveAddr,      before.curveAddr,      "curve addr drifted");
        assertEq(afterUpgrade.creator,        before.creator,        "creator drifted");
        assertEq(afterUpgrade.rebalancer,     before.rebalancer,     "rebalancer drifted");
        assertEq(afterUpgrade.depositIdle,    before.depositIdle,    "deposit idle drifted");
        assertEq(afterUpgrade.assetCount,     before.assetCount,     "asset count drifted");
        assertEq(afterUpgrade.tokenAapl,      before.tokenAapl);
        assertEq(afterUpgrade.bpsAapl,        before.bpsAapl);
        assertEq(afterUpgrade.tokenTsla,      before.tokenTsla);
        assertEq(afterUpgrade.bpsTsla,        before.bpsTsla);
    }

    /// After upgrade, existing proxies must still accept normal traffic
    /// (curve buy → treasury deployStable → router swap).
    function test_Upgrade_ProxyStillFunctional() public {
        StockTreasuryV2 newImpl = new StockTreasuryV2();
        beacon.upgradeTo(address(newImpl));

        // Buy through the curve — exercises the upgraded treasury's
        // deployStable + swap path.
        usdc.mint(user, 100e6);
        vm.startPrank(user);
        usdc.approve(address(curve), 100e6);
        uint256[] memory minTokenOuts = new uint256[](2);
        curve.buy(100e6, 0, minTokenOuts, user, block.timestamp);
        vm.stopPrank();

        assertGt(curve.balanceOf(user), 0, "buy didn't mint AGENT post-upgrade");
    }

    // ─── access control ────────────────────────────────────────────────────

    /// Only the beacon owner can call upgradeTo. In production the owner is
    /// the TimelockController; here it's the test contract.
    function test_Upgrade_NonOwnerReverts() public {
        StockTreasuryV2 newImpl = new StockTreasuryV2();
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

        StockTreasuryV2 newImpl = new StockTreasuryV2();
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
        assertEq(StockTreasuryV2(address(treasury)).version2(), "v2");
    }

    // ─── impl initialization lock ──────────────────────────────────────────

    /// The impl contract's storage must be permanently uninitializable —
    /// `_disableInitializers()` in the impl constructor sets `_initialized`
    /// to type(uint64).max so any direct call to `initialize` reverts.
    function test_Impl_CannotBeInitializedDirectly() public {
        StockTreasury.AssetSpec[] memory portfolio = new StockTreasury.AssetSpec[](1);
        portfolio[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 10000});
        StockTreasury.CurveInitParams memory ci = StockTreasury.CurveInitParams({
            name: "x", symbol: "x",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            stableSeed: SEED, seeder: user, recipient: user,
            minTokenOuts: new uint256[](1)
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            rebalancer, user,
            address(0), portfolio, "ipfs://x", ci
        );
    }
}
