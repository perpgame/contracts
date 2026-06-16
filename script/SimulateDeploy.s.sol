// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Forge dry-run of the upgradeable deploy flow that the Rails worker triggers.
// Deploys the infra (impl + beacon + factory) locally, then calls
// factory.deployTreasury — same path as production minus the timelock and
// permit signing.
//
// Run against the local Anvil fork to:
//   - confirm the BeaconProxy + initialize flow doesn't revert
//   - measure deploy gas (should be much lower than the legacy ~25M big-block
//     budget thanks to the BeaconProxy creation code being ~600 bytes)
//   - verify the predicted treasury address equals the actually-deployed one
//
// Usage:
//   forge script contracts/script/SimulateDeploy.s.sol:SimulateDeploy \
//     --rpc-url http://127.0.0.1:8545 \
//     --broadcast \
//     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {TreasuryFactory} from "../src/TreasuryFactory.sol";

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract SimulateDeploy is Script {
    address constant USDC           = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant LT_HELPER      = 0x69028FFb4e18c068fC65917ca7152c29e4B38B01;
    address constant BOUNCE_FACTORY = 0x65a379FE76C7AdC8037b3522De62B27c0D4e9259;

    uint256 constant PREMIUM_CAP_SUPPLY = 30_000e18;
    uint256 constant EXTRA_PREMIUM      = 3e17;

    // Three of the seeded LTs — 40/30/30 split.
    address constant HYPE5L = 0x18b8539261cF9e760E7fEc4a8a73c50F0AE7baBE;
    address constant BTC5L  = 0xBe4e97a8FceeB1b82D64349FbA6Ff29B65Ad3B7d;
    address constant ETH5L  = 0x6ce8B325252805d2b4b5A6d03eA197d95E0dd582;

    function run() external {
        address user = msg.sender; // also the factory owner here, for simplicity
        uint256 seedUsdcBase = 100e6;

        vm.startBroadcast();

        // Infra
        AgentTreasury impl = new AgentTreasury();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), user);
        TreasuryFactory factory = new TreasuryFactory(
            USDC, LT_HELPER, BOUNCE_FACTORY, address(beacon), user
        );

        // Approve USDC straight to the factory (skipping the permit dance —
        // this is a dry-run; production goes through EIP-2612 signed offline).
        IERC20Permit(USDC).approve(address(factory), seedUsdcBase);

        AgentTreasury.AssetSpec[] memory portfolio = new AgentTreasury.AssetSpec[](3);
        portfolio[0] = AgentTreasury.AssetSpec({symbol: "HYPE5L", lt: HYPE5L, bps: 4000});
        portfolio[1] = AgentTreasury.AssetSpec({symbol: "BTC5L",  lt: BTC5L,  bps: 3000});
        portfolio[2] = AgentTreasury.AssetSpec({symbol: "ETH5L",  lt: ETH5L,  bps: 3000});

        TreasuryFactory.DeployParams memory p = TreasuryFactory.DeployParams({
            user:             user,
            salt:             bytes32(uint256(1)),
            seed:             seedUsdcBase,
            rebalancer:       user, // classic mode for the dry-run
            initialPortfolio: portfolio,
            reasoningCid:     "ipfs://simulated-draft",
            curveName:        "Simulated Token",
            curveSymbol:      "SIM",
            premiumCapSupply: PREMIUM_CAP_SUPPLY,
            extraPremium:     EXTRA_PREMIUM,
            minLtOuts:        new uint256[](3)
        });

        // Build a no-op permit struct. The factory's try/catch swallows the
        // permit failure as long as the allowance is already in place
        // (which our approve() above ensures).
        TreasuryFactory.PermitData memory permit = TreasuryFactory.PermitData({
            value:    seedUsdcBase,
            deadline: block.timestamp + 30 minutes,
            v:        0,
            r:        bytes32(0),
            s:        bytes32(0)
        });

        address predicted = factory.predictTreasury(p);
        console.log("predicted treasury", predicted);

        uint256 gasBefore = gasleft();
        (address treasury, address curve) = factory.deployTreasury(p, permit);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopBroadcast();

        console.log("treasury addr     ", treasury);
        console.log("matches predict   ", treasury == predicted);
        console.log("curve addr        ", curve);
        console.log("deploy gas        ", gasUsed);
    }
}
