// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {IBounceLT} from "../src/interfaces/IBounceLT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockBounceLT} from "./mocks/MockBounceLT.sol";
import {MockBounceFactory} from "./mocks/MockBounceFactory.sol";
import {MockLeveragedTokenHelper} from "./mocks/MockLeveragedTokenHelper.sol";
import {MockTreasuryFactory} from "./mocks/MockTreasuryFactory.sol";

contract AgentTreasuryTest is Test {
    MockUSDC usdc;
    MockBounceLT ltA;
    MockBounceLT ltB;
    MockBounceFactory factory;
    MockLeveragedTokenHelper helper;
    MockTreasuryFactory pauseRegistry;
    AgentTreasury impl;
    UpgradeableBeacon beacon;
    AgentTreasury treasury;
    AgentCurve curve;

    address creator = address(0xC0FFEE);
    address rebalancer = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6; // $1000 seed

    // ─── helpers ──────────────────────────────────────────────────────────

    function setUp() public {
        usdc = new MockUSDC();
        ltA = new MockBounceLT("HYPE 5x Long", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        ltB = new MockBounceLT("BTC 5x Long",  "BTC5L",  address(usdc), "BTC",  5, true, 1e18);
        helper = new MockLeveragedTokenHelper();

        factory = new MockBounceFactory();
        factory.add(address(ltA));
        factory.add(address(ltB));

        pauseRegistry = new MockTreasuryFactory(address(usdc), address(helper), address(factory));

        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob,   100_000 * 1e6);

        _deployAtomically();
    }

    /// Deploy a BeaconProxy fronting AgentTreasury, mirroring the production
    /// upgradeable flow. The BeaconProxy constructor delegatecalls initialize
    /// atomically — same effect as the old `new AgentTreasury(...)` call, but
    /// the resulting address is the proxy, and the upgrade path is open via
    /// the beacon.
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

        treasury = AgentTreasury(_deployProxyWithSeed(_portfolio2(5000, 5000), "ipfs://genesis", ci, alice));
        curve = AgentCurve(treasury.curve());
    }

    /// Deploy a BeaconProxy + initialize() in one call. Pre-approves USDC
    /// from `seeder` to the predicted proxy address so initialize() can
    /// pull the seed during construction. Used by the construction-revert
    /// tests and the pre-donation test.
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
                address(pauseRegistry), portfolio, reasoningCid, ci
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

    function _portfolio2(uint16 bpsA, uint16 bpsB)
        internal view returns (AgentTreasury.AssetSpec[] memory p)
    {
        p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: bpsA});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: bpsB});
    }

    function _emptyMinLtOuts() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    // ─── construction ─────────────────────────────────────────────────────

    function test_Construction_StoresImmutables() public view {
        assertEq(treasury.rebalancer(), rebalancer);
        assertEq(treasury.CREATOR(), creator);
        assertEq(address(treasury.USDC()), address(usdc));
        assertEq(address(treasury.BOUNCE_FACTORY()), address(factory));
        assertTrue(treasury.curve() != address(0));
    }

    function test_Construction_SeedsCurveAtomically() public view {
        // Curve has SEED-scaled AGENT minted to seeder, no race window.
        assertEq(curve.totalSupply(), SEED * 1e12);
        assertEq(curve.balanceOf(alice), SEED * 1e12);
        // Treasury holds LTs worth `SEED` USDC across the two legs.
        assertApproxEqAbs(IERC20(address(ltA)).balanceOf(address(treasury)), 500 * 1e18, 1);
        assertApproxEqAbs(IERC20(address(ltB)).balanceOf(address(treasury)), 500 * 1e18, 1);
    }

    function test_Construction_AbsorbsPreDonatedUsdc() public {
        // Anyone can dust the treasury between deploy txs in production. With
        // the constructor seed pattern that dust is folded into the seeder's
        // share (their per-AGENT NAV is slightly higher), not bricked.
        usdc.mint(bob, 1_000 * 1e6);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        // Bob donates $50 to the treasury address before deploy.
        vm.prank(bob);
        usdc.transfer(predicted, 50 * 1e6);

        // Alice seeds normally.
        vm.prank(alice);
        usdc.approve(predicted, SEED);

        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });

        AgentTreasury t2 = AgentTreasury(_deployProxyWithSeed(
            _portfolio2(5000, 5000), "ipfs://test", ci, address(0)
        ));
        AgentCurve c2 = AgentCurve(t2.curve());

        // Alice still gets SEED*1e12 AGENT. The $50 donation was deployed into
        // LTs, so total nav (= LTs) exceeds SEED by ~$50.
        assertEq(c2.balanceOf(alice), SEED * 1e12);
        assertGt(t2.nav(), SEED);
    }

    function test_Construction_RevertsOnZeroAddressArgs() public {
        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });
        // Build initData with rebalancer_=0 and try to deploy. The proxy
        // constructor delegatecalls initialize, which reverts with
        // InvalidAddress — Address.functionDelegateCall propagates the
        // revert data verbatim, so vm.expectRevert still matches.
        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                address(0), creator,
                address(pauseRegistry), _portfolio2(5000, 5000), "ipfs://test", ci
            )
        );
        vm.expectRevert(AgentTreasury.InvalidAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_Construction_RevertsOnZeroFactory() public {
        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                rebalancer, creator,
                address(0), _portfolio2(5000, 5000), "ipfs://test", ci
            )
        );
        vm.expectRevert(AgentTreasury.InvalidAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_Construction_RevertsWhenWeightsDontSum() public {
        AgentTreasury.AssetSpec[] memory bad = new AgentTreasury.AssetSpec[](2);
        bad[0] = AgentTreasury.AssetSpec({symbol: "A", lt: address(ltA), bps: 4000});
        bad[1] = AgentTreasury.AssetSpec({symbol: "B", lt: address(ltB), bps: 4000});

        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                rebalancer, creator,
                address(pauseRegistry), bad, "ipfs://test", ci
            )
        );
        vm.expectRevert(AgentTreasury.WeightsDoNotSumTo10000.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_Construction_RevertsOnLtNotInFactory() public {
        MockBounceLT rogue =
            new MockBounceLT("rogue", "RGE", address(usdc), "RGE", 1, true, 1e18);
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA),  bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "RGE",    lt: address(rogue), bps: 5000});

        AgentTreasury.CurveInitParams memory ci = AgentTreasury.CurveInitParams({
            name: "X", symbol: "X",
            premiumCapSupply: PREMIUM_CAP_SUPPLY, extraPremium: EXTRA_PREMIUM,
            usdcSeed: SEED, seeder: alice, recipient: alice,
            minLtOuts: new uint256[](2)
        });
        bytes memory initData = abi.encodeCall(
            AgentTreasury.initialize,
            (
                rebalancer, creator,
                address(pauseRegistry), p, "ipfs://test", ci
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.LtNotAllowed.selector, address(rogue))
        );
        new BeaconProxy(address(beacon), initData);
    }

    // ─── deployUsdc ────────────────────────────────────────────────────────

    function test_DeployUsdc_OnlyCurve() public {
        vm.expectRevert(AgentTreasury.NotCurve.selector);
        vm.prank(alice);
        treasury.deployUsdc(100 * 1e6, _emptyMinLtOuts());
    }

    function test_DeployUsdc_RevertsDuringRebalanceInFlight() public {
        // Force async path so executeRebalanceStep flips rebalanceInFlight.
        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);
        // Shift target so a rebalance step has work to do.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory maxRedeem = new uint256[](2);
        maxRedeem[0] = type(uint256).max;
        maxRedeem[1] = type(uint256).max;

        vm.prank(rebalancer);
        treasury.executeRebalanceStep(maxRedeem, zeros, _wide(), zeros);
        assertTrue(treasury.rebalanceInFlight());

        // Now a buy through the curve should revert with RebalancePending.
        usdc.mint(bob, 100 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentTreasury.RebalancePending.selector);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();
    }

    // The factory-level global pause halts both buys and sells; unpausing
    // restores them. The treasury reads pause from its TREASURY_FACTORY ref.
    function test_Pause_HaltsBuysAndSells_ThenResumes() public {
        pauseRegistry.setPaused(true);

        // Buy reverts at deployUsdc's whenNotPaused guard.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentTreasury.Paused.selector);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Sell reverts at withdrawLtsTo's whenNotPaused guard.
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.expectRevert(AgentTreasury.Paused.selector);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // Unpause → both work again.
        pauseRegistry.setPaused(false);
        vm.startPrank(bob);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();
        assertGt(curve.balanceOf(bob), 0, "buy works after unpause");

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp); // does not revert
    }

    // The treasury stores its deploying factory so it can read the pause flag.
    // (The no-op-when-unset path — TREASURY_FACTORY == 0 — is exercised by the
    // AgentCurve/fuzz suites, which deploy with address(0) and transact freely.)
    function test_Pause_TreasuryStoresFactoryRef() public view {
        assertEq(treasury.TREASURY_FACTORY(), address(pauseRegistry));
    }

    function _wide() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
    }

    // Drive the treasury into the async (in-flight) rebalance state by zeroing
    // every LT buffer and shifting the target so a redemption is forced down
    // the prepareRedeem path. Returns with rebalanceInFlight == true.
    function _forceInFlight() internal {
        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinLtOuts();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);
        assertTrue(treasury.rebalanceInFlight(), "expected in-flight after async redeem");
    }

    // Permissionless escape: once Bounce settles every prepared redemption,
    // ANY caller (not just the rebalancer) can clear rebalanceInFlight via
    // settleRebalance() and trading resumes — even if the rebalancer never
    // calls executeRebalanceStep again.
    function test_SettleRebalance_PermissionlessClearAfterSettlement() public {
        _forceInFlight();

        // Simulate Bounce's keeper settling every outstanding credit.
        uint256 cA = ltA.userCredit(address(treasury));
        uint256 cB = ltB.userCredit(address(treasury));
        if (cA > 0) ltA.executeRedemptions(address(treasury), cA);
        if (cB > 0) ltB.executeRedemptions(address(treasury), cB);

        // bob is an unprivileged third party — not the rebalancer.
        vm.prank(bob);
        treasury.settleRebalance();
        assertFalse(treasury.rebalanceInFlight(), "flag should clear once settled");

        // Trading works again: a buy through the curve no longer reverts.
        usdc.mint(bob, 100 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();
        assertGt(curve.balanceOf(bob), 0, "buy should succeed post-settlement");
    }

    // settleRebalance() must be a no-op while a redemption is still pending —
    // it must NOT clear the flag prematurely.
    function test_SettleRebalance_NoOpWhilePending() public {
        _forceInFlight();

        vm.prank(bob);
        treasury.settleRebalance();
        assertTrue(treasury.rebalanceInFlight(), "flag must stay set while a credit is outstanding");
    }

    // ─── symbol pruning (unbounded-growth fix) ─────────────────────────────

    function _single(string memory sym, address lt)
        internal pure returns (AgentTreasury.AssetSpec[] memory p)
    {
        p = new AgentTreasury.AssetSpec[](1);
        p[0] = AgentTreasury.AssetSpec({symbol: sym, lt: lt, bps: 10000});
    }

    // A symbol dropped from the target (bps→0) and fully exited via an atomic
    // redeem is removed from `symbols` in the same executeRebalanceStep.
    function test_Prune_RemovesFullyExitedSymbol() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("HYPE5L", address(ltA)), "ipfs://drop-b");

        uint256[] memory zeros = _emptyMinLtOuts(); // length 2 (A,B both registered at entry)
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);

        assertEq(treasury.assetCount(), 1, "B should be pruned after full exit");
        assertEq(treasury.symbols(0), "HYPE5L", "A should remain");
        (, , bool registered) = treasury.assets("BTC5L");
        assertFalse(registered, "BTC5L should be deregistered");
        // Treasury holds no BTC5L dust.
        assertEq(IERC20(address(ltB)).balanceOf(address(treasury)), 0, "no dust left");
    }

    // A dropped symbol with a still-pending async redemption must NOT be pruned
    // (its userCredit > 0); it is removed only on a later step after settlement.
    function test_Prune_KeepsSymbolWhileRedeemPending() public {
        helper.setBuffer(address(ltB), 0); // force async for B
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("HYPE5L", address(ltA)), "ipfs://drop-b");

        uint256[] memory zeros = _emptyMinLtOuts();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);

        // B has full balance + pending credit → must survive the prune pass.
        assertEq(treasury.assetCount(), 2, "B must remain while redeem pending");
        assertTrue(treasury.rebalanceInFlight());

        // Settle B on Bounce's side, then a follow-up step prunes it.
        uint256 cB = ltB.userCredit(address(treasury));
        ltB.executeRedemptions(address(treasury), cB);

        uint256[] memory zeros2 = _emptyMinLtOuts(); // length 2 (B still registered at entry)
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros2, _wide(), zeros2);

        assertEq(treasury.assetCount(), 1, "B pruned after settlement");
    }

    // Buffer/expectedBaseOut decimals regression: `getLeveragedTokenBufferAssetValue`
    // is 18-dec WAD while `ltToBaseAmount` is 6-dec USDC. The shrink ($300) exceeds
    // B's atomic buffer ($100), so the async path must be chosen. Pre-fix the guard
    // compared 6-dec to 18-dec directly (300e6 <= 100e18 → always true), wrongly
    // taking the atomic branch; the fix scales expectedBaseOut up by 1e12 first.
    function test_ExecuteRebalanceStep_BufferScaleChoosesAsyncWhenInsufficient() public {
        // B starts at $500 (50% of ~$1000 nav); target 20% → must shrink ~$300.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shrink-b");

        // B's atomic-redeem buffer is only ~$100, in 18-dec WAD as the real helper.
        helper.setBuffer(address(ltB), 100 * 1e18);

        uint256[] memory wide = _wide();
        uint256[] memory zeros = _emptyMinLtOuts();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        // $300 shrink > $100 buffer → async prepareRedeem, not atomic redeem.
        assertTrue(treasury.rebalanceInFlight(), "async redeem path chosen");
        assertGt(ltB.userCredit(address(treasury)), 0, "B redemption queued via prepareRedeem");
    }

    // The core regression: rotating assets keeps `symbols.length` at the active
    // set size, not the cumulative count. Without pruning this would climb 2→3→4…
    function test_Prune_RotationKeepsCountBounded() public {
        MockBounceLT ltC = new MockBounceLT("SOL 5x Long", "SOL5L", address(usdc), "SOL", 5, true, 1e18);
        factory.add(address(ltC));

        uint256[] memory z3 = new uint256[](3);
        uint256[] memory w3 = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) w3[i] = type(uint256).max;

        // Rotate [A,B] → [A,C]: drops B, adds C. symbols = [A,B,C] at entry.
        AgentTreasury.AssetSpec[] memory p1 = new AgentTreasury.AssetSpec[](2);
        p1[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p1[1] = AgentTreasury.AssetSpec({symbol: "SOL5L",  lt: address(ltC), bps: 5000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p1, "ipfs://rotate-1");
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(w3, z3, w3, z3);
        assertEq(treasury.assetCount(), 2, "B pruned after rotation 1");

        // Rotate [A,C] → [A,B]: drops C, re-adds B. symbols = [A,C,B] at entry.
        AgentTreasury.AssetSpec[] memory p2 = new AgentTreasury.AssetSpec[](2);
        p2[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 5000});
        p2[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p2, "ipfs://rotate-2");
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(w3, z3, w3, z3);
        assertEq(treasury.assetCount(), 2, "count stays bounded at active-set size after rotation 2");
    }

    // ─── sweepDust (retired-leg eviction) ──────────────────────────────────

    // A retired leg (bps→0) whose LT can no longer be drained through Bounce — a
    // delisted contract after Factory::redeployLt, or a 1-wei dust position whose
    // redeem Bounce rejects — keeps balanceOf != 0 forever, so _pruneExitedSymbols
    // never fires. Worse, the sell loop's atomic redeem of that leg reverts, so the
    // delisted leg bricks executeRebalanceStep entirely. sweepDust evicts it without
    // touching Bounce, sending the stranded balance to CREATOR, and unblocks rebalances.
    function test_SweepDust_EvictsUndrainableRetiredLeg() public {
        uint256[] memory zeros = _emptyMinLtOuts();

        // Drop B (bps→0); B stays registered with its full balance.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("HYPE5L", address(ltA)), "ipfs://drop-b");

        // B's LT is delisted: redeem now reverts and the factory no longer
        // reports it as live. Its balance can never reach 0 through Bounce.
        factory.remove(1);
        ltB.setRedeemReverts(true);
        uint256 stranded = ltB.balanceOf(address(treasury));
        assertGt(stranded, 0, "treasury holds an undrainable B position");

        // The retired-but-undrainable leg bricks executeRebalanceStep: the sell
        // loop hits B's reverting atomic redeem.
        vm.prank(rebalancer);
        vm.expectRevert(bytes("delisted"));
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);

        // sweepDust evicts B without calling Bounce, forwarding its balance to CREATOR.
        uint256 creatorBefore = ltB.balanceOf(creator);
        vm.prank(rebalancer);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit AgentTreasury.DustSwept("BTC5L", address(ltB), stranded);
        treasury.sweepDust("BTC5L");

        assertEq(treasury.assetCount(), 1, "B evicted by sweepDust");
        assertEq(treasury.symbols(0), "HYPE5L", "A remains");
        (, , bool registered) = treasury.assets("BTC5L");
        assertFalse(registered, "BTC5L deregistered");
        assertEq(ltB.balanceOf(creator), creatorBefore + stranded, "stranded balance to CREATOR");
        assertEq(ltB.balanceOf(address(treasury)), 0, "treasury cleared of B");

        // Rebalance is unblocked now that the bricking leg is gone (single-symbol
        // arrays since only HYPE5L remains).
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide1(), _zeros1(), _wide1(), _zeros1());
        assertEq(treasury.assetCount(), 1, "rebalance succeeds post-sweep");
    }

    function test_SweepDust_RejectsFactoryListedRedeemableLeg() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("HYPE5L", address(ltA)), "ipfs://drop-b");

        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.SymbolStillRedeemable.selector, "BTC5L")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("BTC5L");
    }

    function test_SweepDust_AllowsFactoryListedBelowMinDust() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("HYPE5L", address(ltA)), "ipfs://drop-b");

        uint256 dustValue = ltB.ltToBaseAmount(ltB.balanceOf(address(treasury)));
        // sweepDust gates on the global min transaction size, so raise the global
        // floor above the dust value to make this below-min position sweepable.
        factory.setMinTransactionSize(dustValue + 1);

        uint256 swept = ltB.balanceOf(address(treasury));
        vm.prank(rebalancer);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit AgentTreasury.DustSwept("BTC5L", address(ltB), swept);
        treasury.sweepDust("BTC5L");

        assertEq(ltB.balanceOf(address(treasury)), 0, "treasury cleared below-min dust");
        assertEq(ltB.balanceOf(creator), swept, "dust sent to creator");
    }

    function _zeros1() internal pure returns (uint256[] memory m) {
        m = new uint256[](1);
    }

    function _wide1() internal pure returns (uint256[] memory m) {
        m = new uint256[](1);
        m[0] = type(uint256).max;
    }

    function test_SweepDust_OnlyRebalancer() public {
        vm.expectRevert(AgentTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.sweepDust("BTC5L");
    }

    function test_SweepDust_RejectsActiveLeg() public {
        // BTC5L is at 5000 bps — active. Sweeping it must revert.
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.SymbolStillActive.selector, "BTC5L")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("BTC5L");
    }

    function test_SweepDust_RejectsUnknownSymbol() public {
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.UnknownSymbol.selector, "NOPE")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("NOPE");
    }

    function test_SweepDust_RejectsWhileRedeemPending() public {
        // Drop B and force its redeem async so userCredit > 0 (owed USDC).
        helper.setBuffer(address(ltB), 0);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("HYPE5L", address(ltA)), "ipfs://drop-b");
        uint256[] memory zeros = _emptyMinLtOuts();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);
        assertGt(ltB.userCredit(address(treasury)), 0, "credit outstanding");

        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.RedeemPending.selector, "BTC5L")
        );
        vm.prank(rebalancer);
        treasury.sweepDust("BTC5L");
    }

    // ─── migrateLt (Bounce redeploy refresh) ───────────────────────────────

    // After Factory::redeployLt swaps an LT's address for the same product,
    // migrateLt re-points the existing symbol in place. Old (delisted) balance is
    // handed to CREATOR and nav() then tracks the new LT.
    function test_MigrateLt_RepointsSymbolAndMovesStrandedBalance() public {
        // New LT for the same product, at a new address (the redeploy).
        MockBounceLT ltA2 =
            new MockBounceLT("HYPE 5x Long v2", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        factory.add(address(ltA2));

        uint256 oldBal = ltA.balanceOf(address(treasury));
        assertGt(oldBal, 0, "treasury holds the old LT");
        uint256 creatorBefore = ltA.balanceOf(creator);

        vm.prank(rebalancer);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit AgentTreasury.LtMigrated("HYPE5L", address(ltA), address(ltA2), oldBal);
        treasury.migrateLt("HYPE5L", address(ltA2));

        // Symbol now points at the new LT; symbols length unchanged.
        (address lt, , bool registered) = treasury.assets("HYPE5L");
        assertEq(lt, address(ltA2), "symbol re-pointed");
        assertTrue(registered);
        assertEq(treasury.assetCount(), 2, "no orphan, no new slot");
        // Stranded old balance handed to CREATOR for off-protocol redemption.
        assertEq(ltA.balanceOf(creator), creatorBefore + oldBal, "old balance to CREATOR");
        assertEq(ltA.balanceOf(address(treasury)), 0, "treasury drained of old LT");

        // A later target set can now re-weight HYPE5L against the NEW LT without
        // the SymbolTokenMismatch revert that used to orphan it.
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA2), bps: 6000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB),  bps: 4000});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://reweight");
        (, uint16 bps,) = treasury.assets("HYPE5L");
        assertEq(bps, 6000, "re-weight against new LT succeeds");
    }

    function test_MigrateLt_OnlyRebalancer() public {
        vm.expectRevert(AgentTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.migrateLt("HYPE5L", address(ltB));
    }

    function test_MigrateLt_RejectsNonFactoryLt() public {
        MockBounceLT rogue =
            new MockBounceLT("rogue", "RGE", address(usdc), "RGE", 1, true, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.LtNotAllowed.selector, address(rogue))
        );
        vm.prank(rebalancer);
        treasury.migrateLt("HYPE5L", address(rogue));
    }

    function test_MigrateLt_RejectsDuplicateLt() public {
        // Re-pointing HYPE5L at ltB (already used by BTC5L) must revert.
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.DuplicateLt.selector, address(ltB))
        );
        vm.prank(rebalancer);
        treasury.migrateLt("HYPE5L", address(ltB));
    }

    function test_MigrateLt_RejectsUnknownSymbol() public {
        MockBounceLT ltC =
            new MockBounceLT("c", "SOL5L", address(usdc), "SOL", 5, true, 1e18);
        factory.add(address(ltC));
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.UnknownSymbol.selector, "SOL5L")
        );
        vm.prank(rebalancer);
        treasury.migrateLt("SOL5L", address(ltC));
    }

    function test_MigrateLt_RejectsNoOpSameAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentTreasury.SymbolTokenMismatch.selector, "HYPE5L", address(ltA), address(ltA)
            )
        );
        vm.prank(rebalancer);
        treasury.migrateLt("HYPE5L", address(ltA));
    }

    function test_MigrateLt_RejectsWhileOldRedeemPending() public {
        // Force an outstanding async credit on ltA, then attempt migration.
        helper.setBuffer(address(ltA), 0);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(2000, 8000), "ipfs://shrink-a"); // A must shrink → redeem
        uint256[] memory zeros = _emptyMinLtOuts();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(_wide(), zeros, _wide(), zeros);
        assertGt(ltA.userCredit(address(treasury)), 0, "A has pending credit");

        MockBounceLT ltA2 =
            new MockBounceLT("HYPE v2", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        factory.add(address(ltA2));
        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.RedeemPending.selector, "HYPE5L")
        );
        vm.prank(rebalancer);
        treasury.migrateLt("HYPE5L", address(ltA2));
    }

    // ─── withdrawLtsTo ─────────────────────────────────────────────────────

    function test_WithdrawLtsTo_OnlyCurve() public {
        vm.expectRevert(AgentTreasury.NotCurve.selector);
        vm.prank(alice);
        treasury.withdrawLtsTo(alice, 1, 1, 0, true);
    }

    function test_WithdrawLtsTo_RedeemsToUsdcWhenBufferAllows() public {
        // Curve does buys via deployUsdc — let's push a real buy + sell flow.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 bobAgent = curve.balanceOf(bob);
        assertGt(bobAgent, 0);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        // Sell — treasury has no idle USDC, so the deficit is redeemed leg-by-leg
        // to USDC (the mock LTs hold the USDC minted into them, so redeem fills).
        vm.prank(bob);
        curve.sell(bobAgent, bob, 0, true, block.timestamp);

        assertGt(usdc.balanceOf(bob), bobUsdcBefore, "paid in USDC via atomic redeem");
        assertEq(
            IERC20(address(ltA)).balanceOf(bob) + IERC20(address(ltB)).balanceOf(bob),
            0,
            "no raw LTs when the redeem fills"
        );
    }

    // Idle USDC is paid pro-rata, not idle-first. With enough idle to have
    // covered the whole notional in cash (the stale-fee-leak precondition), a
    // seller must still take their proportional LT slice rather than an all-cash
    // exit that leaves the LT (and its pending streaming fee) to other holders.
    function test_WithdrawLtsTo_PaysIdleProRataNotIdleFirst() public {
        // Park $2000 idle: treasury = $500 A + $500 B + $2000 idle, nav = $3000.
        usdc.mint(address(treasury), 2000 * 1e6);

        uint256 aBefore = ltA.balanceOf(address(treasury));
        uint256 bBefore = ltB.balanceOf(address(treasury));

        // Alice sells 1/3 of supply → notional ≈ $1000, which fits in $2000 idle.
        uint256 sellAmount = curve.balanceOf(alice) / 3;
        vm.prank(alice);
        curve.sell(sellAmount, alice, 0, true, block.timestamp);

        // Idle-first would leave the LT untouched; pro-rata takes ~1/3 of each leg.
        assertApproxEqRel(ltA.balanceOf(address(treasury)), (aBefore * 2) / 3, 0.01e18, "A slice taken pro-rata");
        assertApproxEqRel(ltB.balanceOf(address(treasury)), (bBefore * 2) / 3, 0.01e18, "B slice taken pro-rata");
        // Idle was paid only pro-rata (~$666), not drained to the full $1000.
        assertGt(usdc.balanceOf(address(treasury)), 1000 * 1e6, "idle paid pro-rata, not idle-first");
    }

    function test_WithdrawLtsTo_ReturnsRawLtWhenRedeemCannotFill() public {
        // Treasury holds LTs from alice's seed (idle ~0). Bump the rate so each
        // LT is now "worth" 3× the USDC its contract actually holds. Redeeming
        // alice's (whole-supply) slice then needs more USDC than the LT has →
        // redeem reverts InsufficientBalance → the treasury falls back to handing
        // the seller the raw LT slice to convert later.
        ltA.setExchangeRate(3e18);
        ltB.setExchangeRate(3e18);

        uint256 aliceAgent = curve.balanceOf(alice);
        assertGt(aliceAgent, 0);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "no USDC: redeem couldn't fill");
        assertGt(
            IERC20(address(ltA)).balanceOf(alice) + IERC20(address(ltB)).balanceOf(alice),
            0,
            "seller receives raw LTs to convert later"
        );
    }

    // ─── rebalancer rotation (2-step) ──────────────────────────────────────

    function test_RebalancerRotation_TwoStep() public {
        address newReb = address(0xCAFE);

        vm.prank(rebalancer);
        treasury.proposeRebalancer(newReb);
        assertEq(treasury.pendingRebalancer(), newReb);
        assertEq(treasury.rebalancer(), rebalancer, "role unchanged until accept");

        vm.prank(newReb);
        treasury.acceptRebalancer();
        assertEq(treasury.rebalancer(), newReb);
        assertEq(treasury.pendingRebalancer(), address(0));
    }

    function test_RebalancerRotation_AcceptRequiresPendingKey() public {
        vm.prank(rebalancer);
        treasury.proposeRebalancer(address(0xCAFE));

        vm.expectRevert(AgentTreasury.NotPendingRebalancer.selector);
        vm.prank(alice);
        treasury.acceptRebalancer();
    }

    function test_RebalancerRotation_OverwritePending() public {
        vm.startPrank(rebalancer);
        treasury.proposeRebalancer(address(0xCAFE));
        treasury.proposeRebalancer(address(0xDEAD)); // typo fix
        vm.stopPrank();
        assertEq(treasury.pendingRebalancer(), address(0xDEAD));

        // Original wrong address can no longer accept.
        vm.expectRevert(AgentTreasury.NotPendingRebalancer.selector);
        vm.prank(address(0xCAFE));
        treasury.acceptRebalancer();
    }

    function test_RebalancerRotation_OnlyRebalancerCanPropose() public {
        vm.expectRevert(AgentTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.proposeRebalancer(address(0xCAFE));
    }

    // ─── setTargetPortfolio ────────────────────────────────────────────────

    function test_SetTargetPortfolio_OnlyRebalancer() public {
        vm.expectRevert(AgentTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.setTargetPortfolio(_portfolio2(7000, 3000), "ipfs://x");
    }

    function test_SetTargetPortfolio_NewSymbolMustBeInFactory() public {
        // Build a new portfolio that introduces an unapproved LT.
        MockBounceLT rogue =
            new MockBounceLT("rogue", "RGE", address(usdc), "RGE", 1, true, 1e18);
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](3);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA),  bps: 4000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB),  bps: 4000});
        p[2] = AgentTreasury.AssetSpec({symbol: "RGE",    lt: address(rogue), bps: 2000});

        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.LtNotAllowed.selector, address(rogue))
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
    }

    function test_SetTargetPortfolio_AddsLtIfApproved() public {
        // Whitelist a third LT first.
        MockBounceLT ltC =
            new MockBounceLT("eth", "ETH5L", address(usdc), "ETH", 5, true, 1e18);
        factory.add(address(ltC));

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](3);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 4000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 4000});
        p[2] = AgentTreasury.AssetSpec({symbol: "ETH5L",  lt: address(ltC), bps: 2000});

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
        assertEq(treasury.assetCount(), 3);
    }

    function test_SetTargetPortfolio_OldSymbolsGrandfathered() public {
        // Zero out HYPE5L; symbols array should still contain it (no removal),
        // so the existing LT balance stays accounted for in nav().
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 0});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 10000});

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
        assertEq(treasury.assetCount(), 2);
        // Pre-existing HYPE5L position survives even though target is 0.
        assertGt(IERC20(address(ltA)).balanceOf(address(treasury)), 0);
    }

    function test_SetTargetPortfolio_RejectsSymbolLtSwap() public {
        // Same symbol, different LT contract — must revert.
        MockBounceLT ltC =
            new MockBounceLT("hype-impostor", "HYPE5L", address(usdc), "HYPE", 5, true, 1e18);
        factory.add(address(ltC));

        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltC), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 5000});

        vm.expectRevert(
            abi.encodeWithSelector(
                AgentTreasury.SymbolTokenMismatch.selector,
                "HYPE5L", address(ltA), address(ltC)
            )
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://x");
    }

    // The cap is enforced against the LIVE symbols[] (active + grandfathered
    // bps=0 legs), not just the incoming portfolio. A new target whose merged set
    // would exceed MAX_ASSETS reverts, forcing the rebalancer to prune/sweep first.
    function test_SetTargetPortfolio_EnforcesMaxAssetsOnLiveArray() public {
        // setUp already registered 2 symbols (HYPE5L, BTC5L); they linger in
        // symbols[] at bps=0 once dropped. Add MAX_ASSETS-2 new legs so the live
        // array sits exactly at the cap.
        uint16 max = treasury.MAX_ASSETS();
        uint256 newN = uint256(max) - 2;
        AgentTreasury.AssetSpec[] memory full = new AgentTreasury.AssetSpec[](newN);
        for (uint256 i = 0; i < newN; i++) {
            MockBounceLT lt = new MockBounceLT("x", "x", address(usdc), "x", 1, true, 1e18);
            factory.add(address(lt));
            string memory sym = string(abi.encodePacked("S", vm.toString(i)));
            uint16 bps = i == 0 ? uint16(10000 - 100 * (newN - 1)) : uint16(100);
            full[i] = AgentTreasury.AssetSpec({symbol: sym, lt: address(lt), bps: bps});
        }
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(full, "ipfs://fill");
        assertEq(treasury.assetCount(), max, "live array == cap (incl. grandfathered HYPE5L/BTC5L)");

        // Try to add one brand-new symbol. The merged live array would be max + 1 >
        // MAX_ASSETS → revert. The dropped legs still occupy symbols[] (not yet
        // pruned), so the cap bites.
        MockBounceLT extra = new MockBounceLT("e", "e", address(usdc), "e", 1, true, 1e18);
        factory.add(address(extra));
        AgentTreasury.AssetSpec[] memory next = new AgentTreasury.AssetSpec[](2);
        next[0] = AgentTreasury.AssetSpec({symbol: "S0", lt: full[0].lt, bps: 5000});
        // (EXTRA is the only brand-new symbol; S0 already exists.)
        next[1] = AgentTreasury.AssetSpec({symbol: "EXTRA", lt: address(extra), bps: 5000});
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentTreasury.TooManyAssets.selector, uint256(max) + 1, uint256(max)
            )
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(next, "ipfs://over");
    }

    // A NEW symbol must not be allowed to point at an LT already bound to an
    // existing symbol from a PRIOR call. Without the persistent-set scan, the
    // within-array guard misses this: the duplicate LT ends up in symbols[]
    // twice, nav() double-counts the one real balance, and a seller drains the
    // duplicated value via withdrawLtsTo. (Genesis registered HYPE5L -> ltA.)
    function test_SetTargetPortfolio_RejectsDuplicateLtAcrossCalls() public {
        uint256 navBefore = treasury.nav();

        // "DUP" is a fresh symbol, but it reuses ltA which HYPE5L already holds.
        AgentTreasury.AssetSpec[] memory p = new AgentTreasury.AssetSpec[](2);
        p[0] = AgentTreasury.AssetSpec({symbol: "BTC5L", lt: address(ltB), bps: 5000});
        p[1] = AgentTreasury.AssetSpec({symbol: "DUP",   lt: address(ltA), bps: 5000});

        vm.expectRevert(
            abi.encodeWithSelector(AgentTreasury.DuplicateLt.selector, address(ltA))
        );
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(p, "ipfs://dup");

        // State untouched: still two symbols, nav not inflated.
        assertEq(treasury.assetCount(), 2, "no duplicate symbol appended");
        assertEq(treasury.nav(), navBefore, "nav cannot be doubled");
    }

    function test_MinDeployUsdc_RecomputedOnTargetSet() public {
        // 50/50 → minBps=5000 → minDeployUsdc = ceil(10e6 * 10000 / 5000) = 20e6.
        assertEq(treasury.minDeployUsdc(), 20e6);
        // Shift to 99/1 → minBps=100 → minDeployUsdc = ceil(10e6 * 10000 / 100) = 1000e6.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://x");
        assertEq(treasury.minDeployUsdc(), 1000e6);
    }

    function test_MinDeployUsdc_TracksLiveBounceMinTransactionSize() public {
        factory.setMinTransactionSize(25e6);
        assertEq(treasury.minDeployUsdc(), 50e6);

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://x");
        assertEq(treasury.minDeployUsdc(), 2500e6);
    }

    // ─── deploy deferral ───────────────────────────────────────────────────

    // A zeroed leg lingering in the LAST slot of symbols[] must not receive the
    // flooring remainder. Active A/B sum to 100%, so the last (zeroed) leg C
    // would get a few wei of dust; lt.mint rejects that as below minTransactionSize
    // and bricks every deploy-triggering buy. The fix skips it and leaves the dust idle.
    function test_MintLTs_ZeroedLastLeg_DoesNotBrickBuyOnDust() public {
        MockBounceLT ltC = new MockBounceLT("SOL 5x Long", "SOL5L", address(usdc), "SOL", 5, true, 1e18);
        factory.add(address(ltC));

        // Register C (3-leg active) then drop it back to bps 0 — C stays in
        // symbols[] at the last index with a live LT.
        AgentTreasury.AssetSpec[] memory three = new AgentTreasury.AssetSpec[](3);
        three[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: address(ltA), bps: 3400});
        three[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: address(ltB), bps: 3300});
        three[2] = AgentTreasury.AssetSpec({symbol: "SOL5L",  lt: address(ltC), bps: 3300});
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(three, "ipfs://add-c");
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(5000, 5000), "ipfs://drop-c");

        // Real minTransactionSize floor on every leg.
        factory.setMinTransactionSize(10 * 1e6);

        // Odd buy → A,B each take floor(50%) and 1 wei of remainder is left for C.
        uint256[] memory zeros3 = new uint256[](3);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100_000_001);
        curve.buy(100_000_001, 0, zeros3, bob, block.timestamp); // must not revert
        vm.stopPrank();

        assertGt(curve.balanceOf(bob), 0, "buy succeeded despite zeroed last leg");
        assertEq(ltC.balanceOf(address(treasury)), 0, "no dust minted into the zeroed leg");
        assertLe(usdc.balanceOf(address(treasury)), 2, "remainder dust left idle");
    }

    function test_DeployUsdc_DeferredBelowThreshold() public {
        // Shift to 99/1 so minDeployUsdc balloons to $1000.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");

        // A $5 buy is far below the new threshold — USDC should accumulate
        // as idle instead of being deployed into LTs.
        uint256 idleBefore = usdc.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 5 * 1e6);
        vm.expectEmit(true, true, true, false, address(treasury));
        emit AgentTreasury.DeployDeferred(0, 0);
        curve.buy(5 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // $5 buy less the 1% fee ($0.05) → $4.95 lands in the treasury as idle.
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 4_950_000, "idle accumulated");
    }

    function test_DeployUsdc_DefersWhenLiveBounceFloorRaised() public {
        // $1000 deploy at 99/1 would give BTC5L a $10 slice. Once Bounce's
        // live floor is $11, minDeployUsdc rises to $1100 and the buy defers
        // before attempting any below-min mint.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");
        factory.setMinTransactionSize(11 * 1e6);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 ltABefore = ltA.balanceOf(address(treasury));
        uint256 ltBBefore = ltB.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 1000 * 1e6);
        // $1000 buy less the 1% fee → $990 deployable, still below the $1100 floor.
        vm.expectEmit(true, true, true, true, address(treasury));
        emit AgentTreasury.DeployDeferred(990 * 1e6, 1100 * 1e6);
        curve.buy(1000 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertEq(ltA.balanceOf(address(treasury)), ltABefore, "no mint attempted");
        assertEq(ltB.balanceOf(address(treasury)), ltBBefore, "no below-min mint attempted");
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 990 * 1e6, "buy left idle");
    }

    function test_DeployUsdc_DeploysOnceLiveBounceFloorIsMet() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");
        factory.setMinTransactionSize(11 * 1e6);

        uint256 ltABefore = ltA.balanceOf(address(treasury));
        uint256 ltBBefore = ltB.balanceOf(address(treasury));

        // Buy $1200 so that, net of the 1% fee, $1188 is deployable — above the
        // $1100 threshold, and the small leg's 1% share ($11.88) clears the $11 floor.
        vm.startPrank(bob);
        usdc.approve(address(curve), 1200 * 1e6);
        curve.buy(1200 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        assertGt(ltA.balanceOf(address(treasury)), ltABefore, "large leg minted");
        assertGt(ltB.balanceOf(address(treasury)), ltBBefore, "small leg met live floor");
    }

    // ─── paused-LT resilience ──────────────────────────────────────────────

    // A single paused leg must not brick buys: its share is skipped and left
    // idle (the un-paused leg still mints), and the buyer still receives AGENT.
    function test_Buy_SkipsPausedLeg_DoesNotRevert() public {
        // 50/50 HYPE5L/BTC5L. Pause BTC5L (ltB).
        ltB.setMintPaused(true);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 ltABalBefore = ltA.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        // Net of the 1% fee, $99 deploys; ltB's 50% ($49.5) is skipped and stays idle.
        vm.expectEmit(true, false, false, true, address(treasury));
        emit AgentTreasury.MintSkippedPaused("BTC5L", 49_500_000);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Buy succeeded: buyer holds AGENT.
        assertGt(curve.balanceOf(bob), 0, "buy minted AGENT despite paused leg");
        // ltA (un-paused) got its $49.5; ltB's $49.5 sits idle in the treasury.
        assertGt(ltA.balanceOf(address(treasury)), ltABalBefore, "un-paused leg minted");
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 49_500_000, "paused leg's share left idle");
        // No value lost: idle USDC counts in NAV at face value.
    }

    // Once the leg un-pauses, a subsequent buy deploys both the new funds and
    // the previously-stranded idle USDC into the formerly-paused leg.
    function test_Buy_DeploysIdleAfterUnpause() public {
        ltB.setMintPaused(true);
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();
        // Net of the 1% fee: ltB's skipped 50% share is $49.5.
        assertEq(usdc.balanceOf(address(treasury)), 49_500_000, "ltB share idle while paused");

        // Unpause and buy again — idle USDC now deploys into ltB.
        ltB.setMintPaused(false);
        uint256 ltBBefore = ltB.balanceOf(address(treasury));
        vm.startPrank(alice);
        usdc.approve(address(curve), 100 * 1e6);
        curve.buy(100 * 1e6, 0, _emptyMinLtOuts(), alice, block.timestamp);
        vm.stopPrank();

        assertGt(ltB.balanceOf(address(treasury)), ltBBefore, "ltB minted after unpause");
        assertLt(usdc.balanceOf(address(treasury)), 50 * 1e6, "idle drained into ltB");
    }

    // A caller demanding exposure to a paused leg (minLtOuts[i] != 0) must get
    // a revert, not a silent skip — the per-leg floor is honored exactly as the
    // usdcToAllocate == 0 branch does. Mirrors the floor enforced on the live
    // mint path; without it the buyer receives idle USDC instead of leverage.
    function test_Buy_RevertsWhenDemandingExposureToPausedLeg() public {
        ltB.setMintPaused(true); // BTC5L is index 1

        uint256[] memory minLtOuts = new uint256[](2);
        minLtOuts[1] = 1; // demand >=1 unit of the paused leg

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentTreasury.SlippageExceeded.selector);
        curve.buy(100 * 1e6, 0, minLtOuts, bob, block.timestamp);
        vm.stopPrank();
    }

    // Demanding a floor on the un-paused leg while the other leg is paused still
    // succeeds: the live leg's floor is satisfied and the paused leg (floor 0)
    // is skipped to idle. Confirms the fix only reverts on the demanded leg.
    function test_Buy_DemandFloorOnLiveLeg_SkipsPausedLeg() public {
        ltB.setMintPaused(true); // BTC5L (index 1) paused; HYPE5L (index 0) live

        uint256[] memory minLtOuts = new uint256[](2);
        minLtOuts[0] = 1; // demand >=1 unit of the live leg, none of the paused one

        uint256 idleBefore = usdc.balanceOf(address(treasury));

        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit AgentTreasury.MintSkippedPaused("BTC5L", 49_500_000);
        curve.buy(100 * 1e6, 0, minLtOuts, bob, block.timestamp);
        vm.stopPrank();

        assertGt(curve.balanceOf(bob), 0, "buy minted AGENT");
        assertGt(ltA.balanceOf(address(treasury)), 0, "live leg minted");
        // Net of the 1% fee, ltB's skipped 50% share is $49.5.
        assertEq(usdc.balanceOf(address(treasury)), idleBefore + 49_500_000, "paused leg left idle");
    }

    // executeRebalanceStep skips a paused grow-leg instead of reverting the
    // whole step; the rest of the rebalance proceeds.
    function test_ExecuteRebalanceStep_SkipsPausedGrowLeg() public {
        // Target 20/80 so ltB must GROW (buy side). Pause ltB.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(2000, 8000), "ipfs://shift");
        usdc.mint(address(ltA), 1000 * 1e6); // buffer so ltA's redeem is atomic
        ltB.setMintPaused(true);

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();

        // Does not revert; emits the skip for the paused grow leg.
        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit AgentTreasury.MintSkippedPaused("BTC5L", 0);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        // ltA was redeemed down (sell side ran); ltB mint was skipped, USDC idle.
        assertGt(usdc.balanceOf(address(treasury)), 0, "redeemed USDC left idle, mint skipped");
    }

    // A leg whose required shrink is below Bounce's minTransactionSize must be
    // skipped, not reverted — otherwise one dust-level leg bricks the whole
    // step. The mock enforces the floor (redeem/prepareRedeem revert below it),
    // so a clean run here proves the in-contract skip fires first.
    function test_ExecuteRebalanceStep_SkipsSellLegBelowMinTransactionSize() public {
        // 4990/5010 → ltA must shrink ~$1 of its $500. Floor is $2, so the
        // trim is undersized. Cap ltB's grow to 0 so the buy side is a no-op
        // and we isolate the sell-leg behaviour.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(4990, 5010), "ipfs://dust");
        factory.setMinTransactionSize(2 * 1e6);

        uint256 ltABefore = ltA.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        uint256[] memory noMint = _emptyMinLtOuts(); // maxMintUsdc = [0, 0]

        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit AgentTreasury.RedeemSkippedBelowMin("HYPE5L", 0, 0);
        treasury.executeRebalanceStep(wide, zeros, noMint, zeros);

        assertEq(ltA.balanceOf(address(treasury)), ltABefore, "undersized sell leg untouched");
        assertFalse(treasury.rebalanceInFlight(), "no async redeem was prepared");
    }

    // A grow leg below minTransactionSize is likewise skipped, not reverted.
    function test_ExecuteRebalanceStep_SkipsMintLegBelowMinTransactionSize() public {
        // Donate idle USDC so nav rises and BOTH legs sit under target (pure buy
        // side, no sell). 50/50 of a $1100 nav targets ~$550 each; we instead
        // target ltA just $1 above its $500 holding so its grow is undersized.
        usdc.mint(address(treasury), 100 * 1e6);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(4555, 5445), "ipfs://dust-mint");
        factory.setMinTransactionSize(2 * 1e6);

        uint256 ltABefore = ltA.balanceOf(address(treasury));
        uint256 ltBBefore = ltB.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();

        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit AgentTreasury.MintSkippedBelowMin("HYPE5L", 0, 0);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertEq(ltA.balanceOf(address(treasury)), ltABefore, "undersized grow leg untouched");
        assertGt(ltB.balanceOf(address(treasury)), ltBBefore, "well-sized grow leg still minted");
    }

    // The skip honors an explicit fill demand: a non-zero minRedeemUsdc on an
    // undersized leg still reverts, so a caller who insists on a fill is told.
    function test_ExecuteRebalanceStep_UndersizedSellWithFillDemandReverts() public {
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(4990, 5010), "ipfs://dust");
        factory.setMinTransactionSize(2 * 1e6);

        uint256[] memory wide = _wide();
        uint256[] memory noMint = _emptyMinLtOuts();
        uint256[] memory minRedeem = _emptyMinLtOuts();
        minRedeem[0] = 1; // demand a fill on the undersized leg

        vm.prank(rebalancer);
        vm.expectRevert(AgentTreasury.SlippageExceeded.selector);
        treasury.executeRebalanceStep(wide, minRedeem, noMint, _emptyMinLtOuts());
    }

    // ─── rebalance flow ────────────────────────────────────────────────────

    // Buy targets must be sized off the POST-sell nav, not the pre-fee snapshot.
    // Drop A entirely with a 10% redemption fee: the sell nets $450 of A's $500,
    // so the surviving leg B (target 100%) must grow by exactly the realized
    // proceeds. With the stale navAtStart ($1000) the buy would target $1000 and
    // revert (needs $500, only $450 on hand); the post-fee nav ($950) funds it
    // exactly — so this test passing is itself proof the snapshot was refreshed.
    function test_ExecuteRebalanceStep_BuyTargetsUsePostSellNav() public {
        ltA.setRedemptionFeeBps(1000); // 10%, atomic (default buffer is +∞)

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_single("BTC5L", address(ltB)), "ipfs://drop-a");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros); // must not revert

        assertEq(treasury.assetCount(), 1, "A fully exited and pruned");
        assertApproxEqAbs(treasury.nav(), 950 * 1e6, 1e6, "nav fell by the redemption fee");
        assertApproxEqAbs(
            ltB.ltToBaseAmount(ltB.balanceOf(address(treasury))), 950 * 1e6, 1e6, "B grew to the post-fee nav"
        );
        assertLe(usdc.balanceOf(address(treasury)), 1, "proceeds fully deployed, none stranded");
    }

    function test_ExecuteRebalanceStep_AtomicRedeemPath() public {
        // Default helper buffer is +∞ → all redemptions go atomic, never
        // setting rebalanceInFlight. Shift target so a rebalance has work.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        // First make sure ltB has USDC buffer to settle the redeem.
        usdc.mint(address(ltB), 1000 * 1e6);

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);
        assertFalse(treasury.rebalanceInFlight(), "atomic path does not set in-flight");
    }

    // A sell-to-fund-buy rebalance with no idle cash must not revert on the
    // atomic path. The sold leg delivers proceeds NET of Bounce's redemption
    // fee, so the buy is short by exactly the fee; pre-fix the atomic branch
    // reverted InsufficientUsdcForMint. The fix mints the realized net instead.
    function test_ExecuteRebalanceStep_AtomicBuyFundedByNetProceeds_NoRevert() public {
        // Re-weight 50/50 → 80/20: sell B (~$300), buy A. No idle cash post-seed.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        // Bounce charges redemptionFee × leverage on redeem; 1.5% here. Default
        // helper buffer (+∞) keeps the redeem on the atomic branch.
        ltB.setRedemptionFeeBps(150);

        assertEq(usdc.balanceOf(address(treasury)), 0, "no idle cash (normal state)");
        uint256 aBefore = ltA.balanceOf(address(treasury));

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros); // must not revert

        assertGt(ltA.balanceOf(address(treasury)), aBefore, "buy leg grew from net proceeds");
        assertFalse(treasury.rebalanceInFlight(), "atomic path, no async");
        assertLe(usdc.balanceOf(address(treasury)), 1, "net proceeds deployed into buy leg");
    }

    function test_ExecuteRebalanceStep_AsyncRedeemPath_SetsRebalanceInFlight() public {
        // Force async by zeroing buffer.
        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();

        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertTrue(treasury.rebalanceInFlight(), "async path flips flag");
    }

    function test_ExecuteRebalanceStep_SettlementClearsFlag() public {
        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);

        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();

        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);
        assertTrue(treasury.rebalanceInFlight());

        // Simulate Bounce settling the prepared redemption.
        uint256 credit = ltB.userCredit(address(treasury));
        assertGt(credit, 0);
        usdc.mint(address(ltB), 1000 * 1e6); // fund the LT to pay out
        ltB.executeRedemptions(address(treasury), credit);

        // Re-running executeRebalanceStep clears the flag once userCredit==0.
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);
        assertFalse(treasury.rebalanceInFlight(), "flag cleared after settlement");
    }

    // A pending leg whose credit Bounce can no longer settle (its base value
    // dropped below the executor fee) would freeze rebalanceInFlight — and thus
    // all buys/sells — forever. cancelRedeem is the recovery: it zeroes the
    // stuck credit and lets the flag clear.
    function test_CancelRedeem_ClearsStuckInFlightFlag() public {
        // Force B's redemption onto the async path → userCredit set, flag true.
        helper.setBuffer(address(ltB), 0);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shrink-b");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        assertTrue(treasury.rebalanceInFlight(), "async set the flag");
        assertGt(ltB.userCredit(address(treasury)), 0, "B has a pending credit");

        // The whole basket is frozen while the flag is set.
        vm.startPrank(bob);
        usdc.approve(address(curve), 100 * 1e6);
        vm.expectRevert(AgentTreasury.RebalancePending.selector);
        curve.buy(100 * 1e6, 0, zeros, bob, block.timestamp);
        vm.stopPrank();

        // Recovery: cancel the stuck leg's redemption.
        vm.prank(rebalancer);
        treasury.cancelRedeem("BTC5L");

        assertEq(ltB.userCredit(address(treasury)), 0, "credit zeroed by cancel");
        assertFalse(treasury.rebalanceInFlight(), "flag cleared after cancel");

        // Buys work again.
        vm.startPrank(bob);
        curve.buy(100 * 1e6, 0, zeros, bob, block.timestamp);
        vm.stopPrank();
        assertGt(curve.balanceOf(bob), 0, "buy succeeds after recovery");
    }

    function test_CancelRedeem_OnlyRebalancer() public {
        vm.expectRevert(AgentTreasury.NotRebalancer.selector);
        vm.prank(alice);
        treasury.cancelRedeem("BTC5L");
    }

    function test_CancelRedeem_RevertsOnUnknownSymbol() public {
        vm.expectRevert(abi.encodeWithSelector(AgentTreasury.UnknownSymbol.selector, "DOGE5L"));
        vm.prank(rebalancer);
        treasury.cancelRedeem("DOGE5L");
    }

    // Settled async-redemption proceeds must not be deployed by weight by an
    // intervening buy, but the buy's own deposit must still deploy even if the
    // actual redemption payout is lower than the original ltToBaseAmount quote.
    function test_DepositIdle_BuyDoesNotConsumeAsyncProceedsOrDependOnExpectedPayout() public {
        // Target 90/10: A ($500→$900) grows, B ($500→$100) shrinks. Force B async.
        helper.setBuffer(address(ltB), 0);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9000, 1000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        // B's $400-at-prepare-time shrink queued async, but no deposit idle remains.
        assertTrue(treasury.rebalanceInFlight());
        assertEq(treasury.depositIdleUsdc(), 0, "no deposit idle after seed deploy");

        // The exchange rate moves before Bounce settles, so the actual payout is
        // only $200. A reserve based on the old $400 quote would now be stale.
        uint256 credit = ltB.userCredit(address(treasury));
        ltB.setExchangeRate(0.5e18);
        ltB.executeRedemptions(address(treasury), credit);
        treasury.settleRebalance();
        assertFalse(treasury.rebalanceInFlight(), "flag cleared");
        assertEq(usdc.balanceOf(address(treasury)), 200 * 1e6, "actual async payout");
        assertEq(treasury.depositIdleUsdc(), 0, "async payout is not deposit idle");

        // Intervening buy deploys only its own $200 deposit by weight; the
        // async $200 stays idle for the balance-aware rebalance path.
        vm.startPrank(bob);
        usdc.approve(address(curve), 200 * 1e6);
        curve.buy(200 * 1e6, 0, zeros, bob, block.timestamp);
        vm.stopPrank();
        assertApproxEqAbs(usdc.balanceOf(address(treasury)), 200 * 1e6, 1, "async proceeds left idle");
        assertEq(treasury.depositIdleUsdc(), 0, "buy deposit was deployed");

        // The rebalancer's follow-up step deploys them toward target — into the
        // under-weight legs — without relying on any old expected payout.
        uint256 aBefore = ltA.balanceOf(address(treasury));
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);
        assertEq(treasury.depositIdleUsdc(), 0, "no deposit idle after balance-aware deploy");
        assertGt(ltA.balanceOf(address(treasury)), aBefore, "settled funds grew the under-weight leg");
        assertLe(usdc.balanceOf(address(treasury)), 1, "idle deployed toward targets");
    }

    function test_WithdrawLtsTo_BlockedDuringInFlight() public {
        helper.setBuffer(address(ltA), 0);
        helper.setBuffer(address(ltB), 0);
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(8000, 2000), "ipfs://shift");

        uint256[] memory zeros = _emptyMinLtOuts();
        uint256[] memory wide = _wide();
        vm.prank(rebalancer);
        treasury.executeRebalanceStep(wide, zeros, wide, zeros);

        // Sell via curve should revert with RebalancePending.
        uint256 aliceAgent = curve.balanceOf(alice);
        vm.expectRevert(AgentTreasury.RebalancePending.selector);
        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);
    }

    // ─── withdrawLtsTo dual-source payout ──────────────────────────────────

    function test_WithdrawLtsTo_MixedIdleUsdcAndRedeemedPayout() public {
        // Force idle USDC accumulation: shift to 99/1, which raises
        // minDeployUsdc to $1000. A $50 buy defers and leaves USDC idle.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://shift");

        vm.startPrank(bob);
        usdc.approve(address(curve), 50 * 1e6);
        curve.buy(50 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        // Treasury now holds: ~$1000 in LTs (from alice's seed), $50 idle USDC
        // (from bob's deferred buy). Total nav ~$1050.
        uint256 idle = usdc.balanceOf(address(treasury));
        assertGt(idle, 0);
        assertGt(IERC20(address(ltA)).balanceOf(address(treasury)), 0);

        // Alice sells her entire seed share (95.2% of supply → notional ~$1000).
        // Idle ($50) is paid first, the deficit is redeemed from LTs to USDC.
        uint256 aliceAgent = curve.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        curve.sell(aliceAgent, alice, 0, true, block.timestamp);

        // Entire payout is USDC (idle + redeemed); no raw LTs since the mock LTs
        // can cover the redeem.
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore + idle, "USDC = idle + redeemed");
        assertEq(
            IERC20(address(ltA)).balanceOf(alice) + IERC20(address(ltB)).balanceOf(alice),
            0,
            "no raw LTs when redeem fills"
        );
    }

    // ─── nav() ─────────────────────────────────────────────────────────────

    function test_Nav_IncludesIdleUsdcAndLts() public {
        // Force idle accumulation.
        vm.prank(rebalancer);
        treasury.setTargetPortfolio(_portfolio2(9900, 100), "ipfs://x");
        vm.startPrank(bob);
        usdc.approve(address(curve), 50 * 1e6);
        curve.buy(50 * 1e6, 0, _emptyMinLtOuts(), bob, block.timestamp);
        vm.stopPrank();

        uint256 idle = usdc.balanceOf(address(treasury));
        uint256 ltVal = ltA.ltToBaseAmount(IERC20(address(ltA)).balanceOf(address(treasury)))
                      + ltB.ltToBaseAmount(IERC20(address(ltB)).balanceOf(address(treasury)));
        assertEq(treasury.nav(), idle + ltVal);
    }
}
