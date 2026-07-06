// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Deploys DuelMarket — the on-chain PvP duel settlement contract.
//
// Env vars:
//   USDC_ADDRESS      (required) — ERC-20 collateral token.
//                       On HyperEVM mainnet: 0xb88339CB7199b77E23DB6E890353E22632Ba630f
//   DUEL_FEE_RECIPIENT (required) — address that receives the protocol fee.
//   DUEL_FEE_BPS       (required) — fee in basis points (e.g. 200 = 2%).
//   DUEL_OWNER         (required) — initial Ownable owner of the contract.
//
// Usage:
//   forge script contracts/script/DeployDuelMarket.s.sol:DeployDuelMarket \
//     --rpc-url "$HYPEREVM_RPC_URL" \
//     --broadcast \
//     --private-key "$DEPLOYER_PRIVATE_KEY"
//
// After deploy:
//   - Wire the deployed address into Rails as DUEL_MARKET_ADDRESS.
//   - Update web/src/lib/contracts/addresses.ts (DUEL_MARKET).

import {Script, console} from "forge-std/Script.sol";
import {DuelMarket} from "../src/DuelMarket.sol";

contract DeployDuelMarket is Script {
    function run() external returns (DuelMarket market) {
        address usdc         = vm.envAddress("USDC_ADDRESS");
        address feeRecipient = vm.envAddress("DUEL_FEE_RECIPIENT");
        uint16  feeBps       = uint16(vm.envUint("DUEL_FEE_BPS"));
        address owner        = vm.envAddress("DUEL_OWNER");

        vm.startBroadcast();
        market = new DuelMarket(usdc, feeRecipient, feeBps, owner);
        vm.stopBroadcast();

        console.log("================================================");
        console.log("DuelMarket         :", address(market));
        console.log("USDC               :", usdc);
        console.log("Fee recipient      :", feeRecipient);
        console.log("Fee bps            :", feeBps);
        console.log("Owner              :", owner);
        console.log("================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Set DUEL_MARKET_ADDRESS=<market> in Rails.");
        console.log("  2. Update web/src/lib/contracts/addresses.ts.");
    }
}
