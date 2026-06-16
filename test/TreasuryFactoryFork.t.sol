// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {TreasuryFactory} from "../src/TreasuryFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// Fork tests against live HyperEVM state. The full constructor path can NOT
/// run under forge — Bounce LT mints read Hyperliquid system precompiles
/// (0x...0801 etc.) that exist only on the real node — so these tests validate
/// everything up to that boundary:
///   1. the REAL bridged USDC accepts the exact EIP-2612 signature shape the
///      web app's signUsdcPermit produces (the riskiest unknown), and
///   2. factory wiring on real state (permit → transferFrom → CREATE2 →
///      constructor seed pull) succeeds, reverting only at the precompile.
/// Skipped unless HYPEREVM_RPC_URL is set:
///   HYPEREVM_RPC_URL=https://rpc.hyperliquid.xyz/evm forge test --mc TreasuryFactoryForkTest -vv
contract TreasuryFactoryForkTest is Test {
    address constant USDC           = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant LT_HELPER      = 0x69028FFb4e18c068fC65917ca7152c29e4B38B01;
    address constant BOUNCE_FACTORY = 0x65a379FE76C7AdC8037b3522De62B27c0D4e9259;

    // Live Bounce LTs (same trio SimulateDeploy.s.sol uses).
    address constant HYPE5L = 0x18b8539261cF9e760E7fEc4a8a73c50F0AE7baBE;
    address constant BTC5L  = 0xBe4e97a8FceeB1b82D64349FbA6Ff29B65Ad3B7d;
    address constant ETH5L  = 0x6ce8B325252805d2b4b5A6d03eA197d95E0dd582;

    uint256 constant SEED = 100e6; // $100 — above the per-LT mint floor at 30% weights

    uint256 userPk = 0xA11CE;
    address user;
    address deployer = address(0xD3B107E5);

    function _forkOrSkip() internal {
        string memory rpc = vm.envOr("HYPEREVM_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        user = vm.addr(userPk);
        deal(USDC, user, 1_000e6);
    }

    /// Sign an EIP-2612 permit against the real token's DOMAIN_SEPARATOR —
    /// byte-for-byte what the web app's signUsdcPermit produces.
    function _signPermit(address spender, uint256 value, uint256 deadline)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                spender,
                value,
                IERC20Permit(USDC).nonces(user),
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IERC20Permit(USDC).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(userPk, digest);
    }

    /// The critical unknown: does the real bridged USDC accept our permit
    /// signature shape? (Its permit implementation is not OZ's — it sits
    /// behind a proxy at a delegated implementation.)
    function test_Fork_RealUsdcAcceptsPermit() public {
        _forkOrSkip();
        address spender = address(0xFAC707);

        uint256 deadline = block.timestamp + 30 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, SEED, deadline);

        IERC20Permit(USDC).permit(user, spender, SEED, deadline, v, r, s);
        assertEq(IERC20(USDC).allowance(user, spender), SEED);
    }

    /// Factory wiring on real state. The deploy must progress through permit,
    /// transferFrom, CREATE2 prediction/approval, and the constructor's seed
    /// pull, and fail ONLY at the Hyperliquid precompile forge can't simulate.
    /// Any earlier failure (bad permit → InsufficientAllowance, address
    /// mismatch, …) produces a different revert and fails the assertion.
    function test_Fork_DeployReachesPrecompileBoundary() public {
        _forkOrSkip();

        AgentTreasury impl = new AgentTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), address(this));
        TreasuryFactory factory = new TreasuryFactory(
            USDC, LT_HELPER, BOUNCE_FACTORY, address(beacon), deployer
        );

        AgentTreasury.AssetSpec[] memory portfolio = new AgentTreasury.AssetSpec[](3);
        portfolio[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: HYPE5L, bps: 4000});
        portfolio[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: BTC5L,  bps: 3000});
        portfolio[2] = AgentTreasury.AssetSpec({symbol: "ETH5L",  lt: ETH5L,  bps: 3000});

        TreasuryFactory.DeployParams memory p = TreasuryFactory.DeployParams({
            user: user,
            salt: bytes32(uint256(1)),
            seed: SEED,
            rebalancer: user,
            initialPortfolio: portfolio,
            reasoningCid: "ipfs://fork-test",
            curveName: "Fork Test",
            curveSymbol: "FORK",
            premiumCapSupply: 30_000e18,
            extraPremium: 3e17,
            minLtOuts: new uint256[](3)
        });

        uint256 deadline = block.timestamp + 30 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(factory), SEED, deadline);

        vm.prank(deployer);
        try factory.deployTreasury(
            p, TreasuryFactory.PermitData({value: SEED, deadline: deadline, v: v, r: r, s: s})
        ) {
            revert("expected the precompile boundary revert under forge");
        } catch (bytes memory data) {
            // The Bounce mint reads the Hyperliquid spot precompile
            // (0x…0801), which only the real node provides — forge halts the
            // inner frame with an EMPTY revert ("call to non-contract
            // address" is forge-internal diagnostics, not revert data). Every
            // failure in OUR code path carries data: InsufficientAllowance /
            // PermitValueTooLow / AddressMismatch are custom errors, SafeERC20
            // reverts are ABI-encoded. So empty data here means the deploy
            // cleared permit → transferFrom → CREATE2 → constructor seed pull
            // against live contracts and died only at the precompile boundary.
            assertEq(data.length, 0, string.concat("unexpected revert: ", vm.toString(data)));
        }
    }
}
