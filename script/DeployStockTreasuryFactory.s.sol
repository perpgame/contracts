// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Deploys the full upgradeable-treasury infra for the gasless server-deploy
// flow on Robinhood Chain:
//
//   1. StockTokenRegistry       — platform allowlist + Uniswap TWAP valuation.
//                                  Owner = deployer (ops key adds tokens).
//                                  Defaults: twapWindow 30m, minTwapWindow 10m,
//                                  minPoolLiquidity 0 (curated universe).
//   2. AgentTreasury impl       — the logic contract; its own constructor
//                                  calls _disableInitializers() so the impl
//                                  storage is permanently inaccessible.
//   3. UpgradeableBeacon        — points at the impl. Every deployed
//                                  treasury proxy delegates through this.
//   4. TimelockController (48h) — proposer & executor = SAFE_MULTISIG.
//                                  Owns the beacon after step 5. The
//                                  multisig must schedule + wait 48h to
//                                  upgrade.
//   5. transferOwnership(beacon → timelock)
//   6. TreasuryFactory          — points at the beacon. msg.sender becomes
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
//   STOCK_REGISTRY_ADDRESS (optional) — reuse an existing registry instead of
//     deploying a fresh one.
//
// The deployer (msg.sender) ends up as the TreasuryFactory owner, NOT the
// beacon owner. Those roles are intentionally separated:
//   - factory owner       → hot key (Rails worker), signs deployTreasury,
//                           pays gas
//   - beacon owner (timelock → multisig) → cold; only used for upgrades
//
// Usage:
//   forge script contracts/script/DeployStockTreasuryFactory.s.sol:DeployStockTreasuryFactory \
//     --rpc-url "$ROBINHOOD_RPC_URL" \
//     --broadcast \
//     --private-key "$DEPLOYER_PRIVATE_KEY" \
//     --verify
//
// After deploy:
//   - Wire TreasuryFactory address into web/src/lib/contracts/addresses.ts
//     (TREASURY_FACTORY) and Rails (TREASURY_FACTORY_ADDRESS).
//   - Persist the registry + beacon + timelock addresses too — you'll need
//     them for token listings and future upgrades.
//   - Seed the registry: registry.addToken(token, intermediate, feeIn, feeOut,
//     poolIn, poolOut) per memecoin (the rake resolves poolIn/poolOut from the
//     Uniswap factory; see rake robinhood:seed_registry).
//   - WARM UP the pools' oracles before any buy/rebalance: on-chain NAV uses a
//     TWAP, so registry.valueOf reverts until each priced pool has >= minTwapWindow
//     of observation history. Grow cardinality + let observations accrue via
//     script/WarmStockPools.s.sol. Display pricing (StockPrices → QuoterV2 spot)
//     works immediately regardless.

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {StockTreasury} from "../src/StockTreasury.sol";
import {StockTreasuryFactory} from "../src/StockTreasuryFactory.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";

contract DeployStockTreasuryFactory is Script {
    /// Defaults are Robinhood Chain MAINNET; override via env for testnet.
    /// USDG (Paxos Global Dollar), 6 decimals, EIP-2612 permit.
    address constant DEFAULT_STABLE = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// Uniswap v3 SwapRouter02 on Robinhood Chain.
    address constant DEFAULT_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;

    uint256 constant DEFAULT_TIMELOCK_DELAY = 48 hours;

    function run() external {
        address safe = vm.envOr("SAFE_MULTISIG", address(0));
        uint256 delay = vm.envOr("TIMELOCK_DELAY_SECONDS", DEFAULT_TIMELOCK_DELAY);
        address existingRegistry = vm.envOr("STOCK_REGISTRY_ADDRESS", address(0));
        // Factory immutables — must match the chain being deployed to. Mainnet
        // defaults; pass STABLE_ADDRESS / SWAP_ROUTER_ADDRESS for testnet.
        address stable = vm.envOr("STABLE_ADDRESS", DEFAULT_STABLE);
        address swapRouter = vm.envOr("SWAP_ROUTER_ADDRESS", DEFAULT_SWAP_ROUTER);

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
            registry = address(new StockTokenRegistry(msg.sender, stable));
        }

        // 2. Impl. Its constructor disables initializers on its own storage.
        StockTreasury impl = new StockTreasury();

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
        StockTreasuryFactory factory = new StockTreasuryFactory(
            stable, swapRouter, registry, address(beacon), msg.sender
        );

        vm.stopBroadcast();

        console.log("================================================");
        console.log("StockTokenRegistry :", registry);
        console.log("StockTreasury impl :", address(impl));
        console.log("TreasuryBeacon     :", address(beacon));
        console.log("TimelockController :", address(timelock));
        console.log("StockTreasuryFactory:", address(factory));
        console.log("");
        console.log("Beacon owner       :", beacon.owner());
        console.log("Factory owner      :", factory.owner());
        console.log("Timelock delay (s) :", delay);
        console.log("Timelock proposer  :", safe);
        console.log("================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Persist all 5 addresses; you need registry, beacon +");
        console.log("     timelock for listings and future upgrades.");
        console.log("  2. Set STOCK_TREASURY_FACTORY_ADDRESS=<factory> + STOCK_REGISTRY_ADDRESS=<registry> in Rails.");
        console.log("  3. rake robinhood:seed_registry     (resolves pools + addToken per memecoin).");
        console.log("  4. forge script WarmStockPools      (grow oracle cardinality; wait for TWAP history).");
        console.log("  5. Update web/src/lib/contracts/addresses.ts if the factory/registry moved.");
    }
}
