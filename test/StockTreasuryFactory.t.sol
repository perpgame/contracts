// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {AgentCurve} from "../src/AgentCurve.sol";
import {StockTreasuryFactory} from "../src/StockTreasuryFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract StockTreasuryFactoryTest is Test {
    MockUSDC usdc;
    MockStockToken tokenA;
    MockStockToken tokenB;
    MockRegistry registry;
    MockSwapRouter router;
    StockTreasury impl;
    UpgradeableBeacon beacon;
    StockTreasuryFactory factory;

    // user needs a real private key so we can sign EIP-2612 permits
    uint256 userPk = 0xA11CE;
    address user;
    address deployer = address(0xD3B107E5);
    address serverRebalancer = address(0xBEEF);
    address stranger = address(0x5712A17);

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000 * 1e18;
    uint256 constant EXTRA_PREMIUM = 2e18;
    uint256 constant SEED = 1_000 * 1e6; // $1000 seed

    function setUp() public {
        user = vm.addr(userPk);

        usdc = new MockUSDC();
        tokenA = new MockStockToken("Apple Stock", "AAPL");
        tokenB = new MockStockToken("Tesla Stock", "TSLA");

        registry = new MockRegistry(address(usdc));
        registry.addToken(address(tokenA), address(0), 3000, 0);
        registry.addToken(address(tokenB), address(0), 3000, 0);
        registry.setMinTradeStable(10e6);

        router = new MockSwapRouter(address(usdc), address(registry));
        usdc.mint(address(router), 1e15);
        tokenA.mint(address(router), 1e30);
        tokenB.mint(address(router), 1e30);

        // Upgradeable infra: impl → beacon → factory. Beacon owner stays as
        // the test contract since none of these tests exercise the upgrade
        // path (BeaconUpgrade.t.sol covers that separately).
        impl = new StockTreasury();
        beacon = new UpgradeableBeacon(address(impl), address(this));
        factory = new StockTreasuryFactory(
            address(usdc), address(router), address(registry), address(beacon), deployer
        );

        usdc.mint(user, 100_000 * 1e6);
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _params(bytes32 salt, address rebalancer)
        internal view returns (StockTreasuryFactory.DeployParams memory p)
    {
        StockTreasury.AssetSpec[] memory portfolio = new StockTreasury.AssetSpec[](2);
        portfolio[0] = StockTreasury.AssetSpec({symbol: "AAPL", token: address(tokenA), bps: 5000});
        portfolio[1] = StockTreasury.AssetSpec({symbol: "TSLA", token: address(tokenB), bps: 5000});

        p = StockTreasuryFactory.DeployParams({
            user: user,
            salt: salt,
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
    }

    /// EIP-2612 permit signed by `userPk` for `factory` as spender.
    function _signPermit(uint256 value, uint256 deadline)
        internal view returns (StockTreasuryFactory.PermitData memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(factory),
                value,
                usdc.nonces(user),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return StockTreasuryFactory.PermitData({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    function _deploy(bytes32 salt) internal returns (address treasury, address curve) {
        StockTreasuryFactory.DeployParams memory p = _params(salt, serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);
        vm.prank(deployer);
        return factory.deployTreasury(p, permit);
    }

    // ─── end to end ───────────────────────────────────────────────────────

    function test_EndToEnd_DeploysAndSeeds() public {
        uint256 balBefore = usdc.balanceOf(user);
        (address treasury, address curve) = _deploy(bytes32(uint256(1)));

        // Seed pulled exactly once, treasury holds the stock-token basket.
        assertEq(usdc.balanceOf(user), balBefore - SEED);
        assertApproxEqAbs(IERC20(address(tokenA)).balanceOf(treasury), 500 * 1e18, 1);
        assertApproxEqAbs(IERC20(address(tokenB)).balanceOf(treasury), 500 * 1e18, 1);

        // AGENT minted to the user, not the factory.
        assertEq(AgentCurve(curve).balanceOf(user), SEED * 1e12);

        // Roles: user is creator, factory holds nothing and has no allowance left.
        StockTreasury t = StockTreasury(treasury);
        assertEq(t.CREATOR(), user);
        assertEq(t.rebalancer(), serverRebalancer);
        assertEq(t.curve(), curve);
        // Registry/router wiring flows from the factory into the treasury.
        assertEq(address(t.REGISTRY()), address(registry));
        assertEq(address(t.SWAP_ROUTER()), address(router));
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(usdc.allowance(address(factory), treasury), 0);
    }

    function test_Predicted_Equals_Deployed() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(7)), serverRebalancer);
        address predicted = factory.predictTreasury(p);

        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);
        vm.prank(deployer);
        (address treasury,) = factory.deployTreasury(p, permit);
        assertEq(treasury, predicted);
    }

    function test_Emits_TreasuryDeployed() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(9)), serverRebalancer);
        address predicted = factory.predictTreasury(p);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        vm.expectEmit(true, true, false, false, address(factory));
        emit StockTreasuryFactory.TreasuryDeployed(user, predicted, address(0), bytes32(0));
        vm.prank(deployer);
        factory.deployTreasury(p, permit);
    }

    // ─── permit handling ──────────────────────────────────────────────────

    function test_PermitFrontrun_Tolerated() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(2)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        // Griefer submits the same permit first, consuming its nonce.
        vm.prank(stranger);
        usdc.permit(user, address(factory), permit.value, permit.deadline, permit.v, permit.r, permit.s);

        // The factory's inner permit call now reverts, but the allowance is in
        // place, so the deploy must still succeed.
        vm.prank(deployer);
        (address treasury,) = factory.deployTreasury(p, permit);
        assertTrue(treasury != address(0));
    }

    function test_WrongSig_Reverts() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(3)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);
        permit.r = bytes32(uint256(permit.r) ^ 1); // corrupt the signature

        vm.prank(deployer);
        vm.expectRevert(StockTreasuryFactory.InsufficientAllowance.selector);
        factory.deployTreasury(p, permit);
    }

    function test_ExpiredDeadline_Reverts() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(4)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        vm.warp(block.timestamp + 31 minutes);
        vm.prank(deployer);
        vm.expectRevert(StockTreasuryFactory.InsufficientAllowance.selector);
        factory.deployTreasury(p, permit);
    }

    function test_PermitValueBelowSeed_Reverts() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(5)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED - 1, block.timestamp + 30 minutes);

        vm.prank(deployer);
        vm.expectRevert(StockTreasuryFactory.PermitValueTooLow.selector);
        factory.deployTreasury(p, permit);
    }

    function test_InsufficientBalance_Reverts() public {
        // Permit is valid but the user moved their stable away after signing.
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(6)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        uint256 bal = usdc.balanceOf(user);
        vm.prank(user);
        usdc.transfer(stranger, bal);

        vm.prank(deployer);
        vm.expectRevert(); // SafeERC20 transferFrom failure
        factory.deployTreasury(p, permit);
    }

    // ─── access control & idempotency ─────────────────────────────────────

    function test_NonOwner_Reverts() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(8)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.deployTreasury(p, permit);
    }

    function test_SameSalt_SecondDeploy_Reverts() public {
        _deploy(bytes32(uint256(10)));

        // Same (user, salt) → same CREATE2 address, which already has code.
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(10)), serverRebalancer);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);
        vm.prank(deployer);
        vm.expectRevert();
        factory.deployTreasury(p, permit);
    }

    function test_DifferentSalts_DeployIndependently() public {
        (address t1,) = _deploy(bytes32(uint256(11)));
        (address t2,) = _deploy(bytes32(uint256(12)));
        assertTrue(t1 != t2);
    }

    function test_ClassicMode_RebalancerIsUser() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(13)), user);
        StockTreasuryFactory.PermitData memory permit = _signPermit(SEED, block.timestamp + 30 minutes);
        vm.prank(deployer);
        (address treasury,) = factory.deployTreasury(p, permit);
        assertEq(StockTreasury(treasury).rebalancer(), user);
    }

    function test_Rescue_OwnerOnly() public {
        usdc.mint(address(factory), 123e6);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.rescue(address(usdc), stranger, 123e6);

        vm.prank(deployer);
        factory.rescue(address(usdc), user, 123e6);
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    function test_SetPaused_OwnerOnly() public {
        assertFalse(factory.paused());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setPaused(true);

        vm.prank(deployer);
        factory.setPaused(true);
        assertTrue(factory.paused(), "owner can pause");

        vm.prank(deployer);
        factory.setPaused(false);
        assertFalse(factory.paused(), "owner can unpause");
    }

    function test_SetFeeRecipient_OwnerOnly() public {
        assertEq(factory.feeRecipient(), factory.DEFAULT_FEE_RECIPIENT());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFeeRecipient(user);

        vm.prank(deployer);
        factory.setFeeRecipient(user);
        assertEq(factory.feeRecipient(), user, "owner redirected the fee recipient");

        // Cannot null the recipient.
        vm.prank(deployer);
        vm.expectRevert(StockTreasuryFactory.InvalidAddress.selector);
        factory.setFeeRecipient(address(0));
    }

    function test_SetFeeBps_OwnerOnlyAndCapped() public {
        assertEq(factory.feeBps(), factory.DEFAULT_FEE_BPS());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFeeBps(200);

        vm.prank(deployer);
        factory.setFeeBps(200);
        assertEq(factory.feeBps(), 200, "owner adjusted the rate");

        // Above the cap reverts.
        uint16 max = factory.MAX_FEE_BPS();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(StockTreasuryFactory.FeeBpsTooHigh.selector, max + 1, max));
        factory.setFeeBps(max + 1);
    }

    function test_ZeroSeed_Reverts() public {
        StockTreasuryFactory.DeployParams memory p = _params(bytes32(uint256(14)), serverRebalancer);
        p.seed = 0;
        StockTreasuryFactory.PermitData memory permit = _signPermit(0, block.timestamp + 30 minutes);

        vm.prank(deployer);
        vm.expectRevert(StockTreasuryFactory.ZeroSeed.selector);
        factory.deployTreasury(p, permit);
    }
}
