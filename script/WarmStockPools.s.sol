// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Grows the observation-buffer cardinality of every pool the StockTokenRegistry
// prices through, so its TWAP valuation (valueOf/amountOf) becomes usable.
//
// WHY: on-chain NAV is a Uniswap TWAP over `twapWindow` seconds. A fresh v3 pool
// has observationCardinality == 1 (only the latest observation), so observe()
// over any real window reverts "OLD" and registry.valueOf reverts — which would
// brick the first buy/rebalance of any basket holding that token. Enlarging the
// ring buffer lets observations accrue; after ~minTwapWindow of trading the
// TWAP is serviceable. (Display pricing uses QuoterV2 spot and is unaffected.)
//
// Run AFTER seed_registry (needs poolIn/poolOut populated). Idempotent: pools
// already at/above the target are skipped. Growing cardinality is permissionless
// — any signer works; it just costs gas per pool that needs SSTORE slots.
//
// Env:
//   STOCK_REGISTRY_ADDRESS (required)
//   TWAP_CARDINALITY       (optional, default 120) — buffer slots to target.
//                          At ~one obs per block, 120 comfortably spans a 30m
//                          window on Robinhood Chain's block time.
//
// Usage:
//   forge script contracts/script/WarmStockPools.s.sol:WarmStockPools \
//     --rpc-url "$ROBINHOOD_RPC_URL" --broadcast --private-key "$DEPLOYER_PRIVATE_KEY"

import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";

interface IRegistryRead {
    function tokenCount() external view returns (uint256);
    function tokenList(uint256) external view returns (address);
    function tokens(address)
        external
        view
        returns (bool enabled, address intermediate, uint24 feeIn, uint24 feeOut, address poolIn, address poolOut);
}

contract WarmStockPools is Script {
    function run() external {
        address registry = vm.envAddress("STOCK_REGISTRY_ADDRESS");
        uint16 target = uint16(vm.envOr("TWAP_CARDINALITY", uint256(120)));
        IRegistryRead reg = IRegistryRead(registry);
        uint256 n = reg.tokenCount();

        // Dedupe pools (poolIn — the USDG/WETH hop — is shared across tokens).
        address[] memory seen = new address[](n * 2);
        uint256 count;

        vm.startBroadcast();
        for (uint256 i; i < n; i++) {
            address token = reg.tokenList(i);
            (,,,, address poolIn, address poolOut) = reg.tokens(token);
            count = _warm(poolIn, target, seen, count);
            count = _warm(poolOut, target, seen, count);
        }
        vm.stopBroadcast();

        console.log("warmed pools:", count);
        console.log("target cardinality:", target);
        console.log("Wait >= registry.minTwapWindow (default 600s) of trading before buys/rebalances.");
    }

    function _warm(address pool, uint16 target, address[] memory seen, uint256 count) internal returns (uint256) {
        if (pool == address(0)) return count;
        for (uint256 j; j < count; j++) {
            if (seen[j] == pool) return count; // already handled
        }
        seen[count] = pool;

        (,,, uint16 cardNext,,,) = _cardinality(pool);
        if (cardNext < target) {
            IUniswapV3Pool(pool).increaseObservationCardinalityNext(target);
            console.log("grew pool", pool);
        } else {
            console.log("pool already at target", pool);
        }
        return count + 1;
    }

    // Returns slot0 with observationCardinalityNext in the 4th slot we read.
    function _cardinality(address pool)
        internal
        view
        returns (uint160, int24, uint16, uint16 cardinalityNext, uint16, uint8, bool)
    {
        (uint160 a, int24 b, uint16 c, uint16 card, uint16 cardNext, uint8 f, bool g) =
            IUniswapV3Pool(pool).slot0();
        // Grow decisions key off the *next* target (what future observations use).
        card; // silence unused
        return (a, b, c, cardNext, card, f, g);
    }
}
