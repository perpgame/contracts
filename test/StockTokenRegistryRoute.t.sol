// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// Security-critical coverage of the Uniswap v3 packed-path builder. The
/// treasury feeds these exact bytes straight into SWAP_ROUTER.exactInput, so a
/// mis-ordered token/fee sequence would silently route trades through the wrong
/// pools. These tests assert the EXACT bytes, not just a decoded shape.
contract StockTokenRegistryRouteTest is Test {
    MockUSDC stable; // the 6-dec USDG stand-in
    MockStockToken token;
    MockAggregator feed;
    StockTokenRegistry registry;

    // A stand-in for the WETH intermediate; never called, just an address in
    // the path.
    address constant WETH = address(0xE7A);

    function setUp() public {
        stable = new MockUSDC();
        token = new MockStockToken("Apple Stock", "AAPL");
        feed = new MockAggregator(8, 1e8);
        registry = new StockTokenRegistry(address(this), address(stable));
    }

    // ─── path building ──────────────────────────────────────────────────────

    function test_Path_TwoHop_ExactBytes() public {
        registry.addToken(address(token), address(feed), WETH, 500, 3000);

        assertEq(
            registry.buyPath(address(token)),
            abi.encodePacked(address(stable), uint24(500), WETH, uint24(3000), address(token)),
            "buyPath: stable -feeIn-> WETH -feeOut-> token"
        );
        assertEq(
            registry.sellPath(address(token)),
            abi.encodePacked(address(token), uint24(3000), WETH, uint24(500), address(stable)),
            "sellPath: token -feeOut-> WETH -feeIn-> stable"
        );
    }

    function test_Path_Direct_ExactBytes() public {
        registry.addToken(address(token), address(feed), address(0), 500, 0);

        assertEq(
            registry.buyPath(address(token)),
            abi.encodePacked(address(stable), uint24(500), address(token)),
            "buyPath: stable -feeIn-> token"
        );
        assertEq(
            registry.sellPath(address(token)),
            abi.encodePacked(address(token), uint24(500), address(stable)),
            "sellPath: token -feeIn-> stable"
        );
    }

    /// setRoute flips a direct token to a two-hop route (and its fee tiers),
    /// and the emitted path changes accordingly.
    function test_SetRoute_UpdatesPath() public {
        registry.addToken(address(token), address(feed), address(0), 500, 0);

        registry.setRoute(address(token), WETH, 100, 3000);

        assertEq(
            registry.buyPath(address(token)),
            abi.encodePacked(address(stable), uint24(100), WETH, uint24(3000), address(token)),
            "buyPath reflects new two-hop route"
        );
        assertEq(
            registry.sellPath(address(token)),
            abi.encodePacked(address(token), uint24(3000), WETH, uint24(100), address(stable)),
            "sellPath reflects new two-hop route"
        );
        assertEq(registry.poolFee(address(token)), 100, "poolFee tracks feeIn");
    }

    // ─── route validation ────────────────────────────────────────────────────

    function test_AddToken_RevertsInvalidRoute_FeeInZero() public {
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.addToken(address(token), address(feed), address(0), 0, 0);
    }

    function test_AddToken_RevertsInvalidRoute_IntermediateWithoutFeeOut() public {
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.addToken(address(token), address(feed), WETH, 500, 0);
    }

    function test_SetRoute_RevertsInvalidRoute_FeeInZero() public {
        registry.addToken(address(token), address(feed), address(0), 500, 0);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.setRoute(address(token), address(0), 0, 0);
    }

    function test_SetRoute_RevertsInvalidRoute_IntermediateWithoutFeeOut() public {
        registry.addToken(address(token), address(feed), address(0), 500, 0);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.setRoute(address(token), WETH, 500, 0);
    }
}
