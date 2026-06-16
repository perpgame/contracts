// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Deploys the full upgradeable-treasury infra for the gasless server-deploy
// flow:
//
//   1. AgentTreasury impl       — the logic contract; its own constructor
//                                  calls _disableInitializers() so the impl
//                                  storage is permanently inaccessible.
//   2. UpgradeableBeacon        — points at the impl. Every deployed
//                                  treasury proxy delegates through this.
//   3. TimelockController (48h) — proposer & executor = SAFE_MULTISIG.
//                                  Owns the beacon after step 4. The
//                                  multisig must schedule + wait 48h to
//                                  upgrade.
//   4. transferOwnership(beacon → timelock)
//   5. TreasuryFactory          — points at the beacon. msg.sender becomes
//                                  the factory owner (= the address that
//                                  Rails signs deployTreasury with).
//
// Env vars:
//   SAFE_MULTISIG (required for production)
//     The Gnosis Safe address that proposes + executes upgrade calls on the
//     timelock. If unset, FALLS BACK to msg.sender with a loud warning — only
//     use this for local/test deployments.
//
//   TIMELOCK_DELAY_SECONDS (optional, default 172800 = 48h)
//
// The deployer (msg.sender) ends up as the TreasuryFactory owner, NOT the
// beacon owner. Those roles are intentionally separated:
//   - factory owner       → hot key (Rails worker), signs deployTreasury,
//                           pays gas
//   - beacon owner (timelock → multisig) → cold; only used for upgrades
//
// The factory bytecode is now ~600 bytes (BeaconProxy initcode) instead of
// the ~12KB it embedded before, so big-block opt-in is likely no longer
// required for the factory deploy itself. The impl deploy still embeds
// AgentTreasury's full code (~12KB) and DOES need big blocks.
//
// Usage:
//   forge script contracts/script/DeployTreasuryFactory.s.sol:DeployTreasuryFactory \
//     --rpc-url "$HYPEREVM_RPC_URL" \
//     --broadcast \
//     --private-key "$DEPLOYER_PRIVATE_KEY" \
//     --verify
//
// After deploy:
//   - Wire TreasuryFactory address into web/src/lib/contracts/addresses.ts
//     (TREASURY_FACTORY) and Rails (TREASURY_FACTORY_ADDRESS).
//   - Persist the beacon + timelock addresses too — you'll need them for
//     future upgrades.

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {TreasuryFactory} from "../src/TreasuryFactory.sol";

contract DeployTreasuryFactory is Script {
    address constant USDC           = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant LT_HELPER      = 0x69028FFb4e18c068fC65917ca7152c29e4B38B01;
    address constant BOUNCE_FACTORY = 0x65a379FE76C7AdC8037b3522De62B27c0D4e9259;

    uint256 constant DEFAULT_TIMELOCK_DELAY = 48 hours;

    function run() external {
        address safe = vm.envOr("SAFE_MULTISIG", address(0));
        uint256 delay = vm.envOr("TIMELOCK_DELAY_SECONDS", DEFAULT_TIMELOCK_DELAY);

        if (safe == address(0)) {
            console.log("================================================");
            console.log("WARNING: SAFE_MULTISIG env var not set.");
            console.log("Falling back to msg.sender as timelock controller.");
            console.log("DO NOT use this configuration in production --");
            console.log("a single EOA can upgrade the beacon arbitrarily.");
            console.log("================================================");
            safe = msg.sender;
        }

        vm.startBroadcast();

        // 1. Impl. Its constructor disables initializers on its own storage.
        AgentTreasury impl = new AgentTreasury();

        // 2. Beacon. Initial owner = deployer; we transfer to the timelock
        //    in step 4 once we have the timelock address.
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), msg.sender);

        // 3. Timelock. Same address is proposer + executor (the Safe).
        //    Admin = address(0) → fully self-administered after deployment,
        //    no superuser can bypass the delay.
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = safe;
        executors[0] = safe;
        TimelockController timelock = new TimelockController(delay, proposers, executors, address(0));

        // 4. Hand the beacon to the timelock. After this, only a timelock-
        //    routed call from the Safe can call beacon.upgradeTo(...).
        beacon.transferOwnership(address(timelock));

        // 5. Factory. msg.sender (= the platform deployer key Rails signs
        //    with) becomes the factory owner — the only address allowed to
        //    call deployTreasury.
        TreasuryFactory factory = new TreasuryFactory(
            USDC, LT_HELPER, BOUNCE_FACTORY, address(beacon), msg.sender
        );

        vm.stopBroadcast();

        console.log("================================================");
        console.log("AgentTreasury impl :", address(impl));
        console.log("TreasuryBeacon     :", address(beacon));
        console.log("TimelockController :", address(timelock));
        console.log("TreasuryFactory    :", address(factory));
        console.log("");
        console.log("Beacon owner       :", beacon.owner());
        console.log("Factory owner      :", factory.owner());
        console.log("Timelock delay (s) :", delay);
        console.log("Timelock proposer  :", safe);
        console.log("================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Persist all 4 addresses; you need beacon + timelock");
        console.log("     for future upgrades.");
        console.log("  2. Set TREASURY_FACTORY_ADDRESS=<factory> in Rails.");
        console.log("  3. Update web/src/lib/contracts/addresses.ts.");
    }
}
