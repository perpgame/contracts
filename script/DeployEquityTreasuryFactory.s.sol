// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Deploys the full upgradeable-treasury infra for the gasless server-deploy
// flow for REAL tokenized equities on Robinhood Chain. This is the EQUITY
// sibling of DeployStockTreasuryFactory — same shape, same role separation; the
// substantive differences are the valuation + execution venue:
//
//   - valuation: Chainlink feeds via EquityRegistry (NOT Uniswap v3 TWAP)
//   - execution: the forked Uniswap v4 UniversalRouter (NOT v3 SwapRouter02)
//
// The two factories coexist, one per asset class, and share nothing at runtime.
//
//   1. EquityRegistry           — Chainlink-feed allowlist + v4 pool marks.
//                                  Owner = deployer (ops key adds tokens with
//                                  addToken(token, feed, fee, tickSpacing,
//                                  heartbeat)). Reads pool state through the v4
//                                  StateView singleton.
//   2. EquityTreasury impl       — the logic contract; its own constructor
//                                  calls _disableInitializers() so the impl
//                                  storage is permanently inaccessible.
//   3. UpgradeableBeacon         — points at the impl. Every deployed equity
//                                  treasury proxy delegates through this.
//   4. TimelockController (48h) — proposer & executor = SAFE_MULTISIG.
//                                  Owns the beacon after step 5. The multisig
//                                  must schedule + wait 48h to upgrade.
//   5. transferOwnership(beacon → timelock)
//   6. EquityTreasuryFactory     — points at the beacon + forked v4 router.
//                                  msg.sender becomes the factory owner (= the
//                                  address Rails signs deployTreasury with).
//
// Env vars:
//   SAFE_MULTISIG (required for production)
//     The Gnosis Safe address that proposes + executes upgrade calls on the
//     timelock. If unset, FALLS BACK to msg.sender with a loud warning — only
//     use this for local/test deployments.
//
//   TIMELOCK_DELAY_SECONDS  (optional, default 172800 = 48h)
//   EQUITY_REGISTRY_ADDRESS (optional) — reuse an existing registry instead of
//     deploying a fresh one.
//   STABLE_ADDRESS          (optional) — override the stable (defaults to mainnet USDG).
//   ROUTER_ADDRESS          (optional) — the forked v4 UniversalRouter (defaults to mainnet).
//   STATE_VIEW_ADDRESS      (optional) — the v4 StateView singleton (defaults to mainnet).
//   SEQUENCER_UPTIME_FEED   (optional) — Chainlink L2 sequencer-uptime feed; 0 if none.
//
// The deployer (msg.sender) ends up as the EquityTreasuryFactory owner, NOT the
// beacon owner. Those roles are intentionally separated:
//   - factory owner       → hot key (Rails worker), signs deployTreasury, pays gas
//   - beacon owner (timelock → multisig) → cold; only used for upgrades
//
// Usage:
//   forge script contracts/script/DeployEquityTreasuryFactory.s.sol:DeployEquityTreasuryFactory \
//     --rpc-url "$ROBINHOOD_RPC_URL" \
//     --broadcast \
//     --private-key "$DEPLOYER_PRIVATE_KEY" \
//     --verify
//
// After deploy:
//   - Wire EquityTreasuryFactory + EquityRegistry addresses into Rails
//     (EQUITY_TREASURY_FACTORY_ADDRESS / EQUITY_REGISTRY_ADDRESS) and the web
//     addresses map. Persist the beacon + timelock too — needed for upgrades.
//   - Seed the registry: registry.addToken(token, feed, fee, tickSpacing,
//     heartbeat) per curated equity (see db/stock_candidates.yml).
//   - Unlike the memecoin path there is NO TWAP-history warm-up: equities price
//     off Chainlink and are tradeable as soon as their feed is fresh.

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {EquityTreasury} from "../src/EquityTreasury.sol";
import {EquityTreasuryFactory} from "../src/EquityTreasuryFactory.sol";
import {EquityRegistry} from "../src/EquityRegistry.sol";

contract DeployEquityTreasuryFactory is Script {
    /// Defaults are Robinhood Chain MAINNET; override via env for testnet.
    /// USDG (Paxos Global Dollar), 6 decimals, EIP-2612 permit.
    address constant DEFAULT_STABLE = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// The forked Uniswap v4 UniversalRouter (equity execution venue).
    address constant DEFAULT_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    /// Uniswap v4 StateView singleton (pool-state reads for the registry).
    address constant DEFAULT_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    uint256 constant DEFAULT_TIMELOCK_DELAY = 48 hours;

    function run() external {
        address safe = vm.envOr("SAFE_MULTISIG", address(0));
        uint256 delay = vm.envOr("TIMELOCK_DELAY_SECONDS", DEFAULT_TIMELOCK_DELAY);
        address existingRegistry = vm.envOr("EQUITY_REGISTRY_ADDRESS", address(0));
        // Factory/registry immutables — must match the chain being deployed to.
        // Mainnet defaults; pass the overrides for testnet.
        address stable = vm.envOr("STABLE_ADDRESS", DEFAULT_STABLE);
        address router = vm.envOr("ROUTER_ADDRESS", DEFAULT_ROUTER);
        address stateView = vm.envOr("STATE_VIEW_ADDRESS", DEFAULT_STATE_VIEW);
        // Chainlink L2 sequencer-uptime feed. Optional (address(0) = none): the
        // registry stores it but a real deployment should set it once confirmed.
        address sequencerUptimeFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));

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

        // 1. Registry (or reuse). Owner = deployer so the ops key can list
        //    tokens; hand to a multisig later via transferOwnership.
        address registry = existingRegistry;
        if (registry == address(0)) {
            registry = address(new EquityRegistry(msg.sender, stable, stateView, sequencerUptimeFeed));
        }

        // 2. Impl. Its constructor disables initializers on its own storage.
        EquityTreasury impl = new EquityTreasury();

        // 3. Beacon. Initial owner = deployer; we transfer to the timelock
        //    in step 5 once we have the timelock address.
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), msg.sender);

        // 4. Timelock. Same address is proposer + executor (the Safe).
        //    Admin = address(0) → fully self-administered after deployment,
        //    no superuser can bypass the delay.
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = safe;
        executors[0] = safe;
        TimelockController timelock = new TimelockController(delay, proposers, executors, address(0));

        // 5. Hand the beacon to the timelock. After this, only a timelock-
        //    routed call from the Safe can call beacon.upgradeTo(...).
        beacon.transferOwnership(address(timelock));

        // 6. Factory. msg.sender (= the platform deployer key Rails signs
        //    with) becomes the factory owner — the only address allowed to
        //    call deployTreasury.
        EquityTreasuryFactory factory = new EquityTreasuryFactory(
            stable, router, registry, address(beacon), msg.sender
        );

        vm.stopBroadcast();

        console.log("================================================");
        console.log("EquityRegistry       :", registry);
        console.log("EquityTreasury impl  :", address(impl));
        console.log("TreasuryBeacon       :", address(beacon));
        console.log("TimelockController   :", address(timelock));
        console.log("EquityTreasuryFactory:", address(factory));
        console.log("");
        console.log("Beacon owner         :", beacon.owner());
        console.log("Factory owner        :", factory.owner());
        console.log("v4 UniversalRouter   :", router);
        console.log("v4 StateView         :", stateView);
        console.log("Sequencer feed       :", sequencerUptimeFeed);
        console.log("Timelock delay (s)   :", delay);
        console.log("Timelock proposer    :", safe);
        console.log("================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Persist all 5 addresses; you need registry, beacon +");
        console.log("     timelock for listings and future upgrades.");
        console.log("  2. Set EQUITY_TREASURY_FACTORY_ADDRESS=<factory> + EQUITY_REGISTRY_ADDRESS=<registry> in Rails.");
        console.log("  3. Seed the registry: addToken(token, feed, fee, tickSpacing, heartbeat) per curated equity.");
        console.log("  4. No TWAP warm-up needed: equities price off Chainlink and trade once their feed is fresh.");
        console.log("  5. Update web/src/lib/contracts/addresses.ts if the factory/registry moved.");
    }
}
