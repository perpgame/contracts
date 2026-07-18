// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockTokenRegistry} from "../src/StockTokenRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// Security-critical coverage of the Uniswap v3 packed-path builder + route
/// validation. The treasury feeds these exact bytes straight into
/// SWAP_ROUTER.exactInput, so a mis-ordered token/fee sequence would silently
/// route trades through the wrong pools. These tests assert the EXACT bytes,
/// and that a declared route must match the real pools it names.
contract StockTokenRegistryRouteTest is Test {
    MockUSDC stable; // the 6-dec USDG stand-in
    MockStockToken token;
    StockTokenRegistry registry;

    // A stand-in for the WETH intermediate.
    address constant WETH = address(0xE7A);

    function setUp() public {
        vm.warp(2_000_000);
        stable = new MockUSDC();
        token = new MockStockToken("Apple Stock", "AAPL");
        registry = new StockTokenRegistry(address(this), address(stable));
    }

    // Pool helpers — each pairs the declared tokens at the declared fee so the
    // registry's _checkPool validation passes.
    function _poolStableToken(uint24 fee) internal returns (address) {
        return address(new MockUniswapV3Pool(address(stable), address(token), fee, 1e18));
    }

    function _poolStableWeth(uint24 fee) internal returns (address) {
        return address(new MockUniswapV3Pool(address(stable), WETH, fee, 1e18));
    }

    function _poolWethToken(uint24 fee) internal returns (address) {
        return address(new MockUniswapV3Pool(WETH, address(token), fee, 1e18));
    }

    // ─── path building ──────────────────────────────────────────────────────

    function test_Path_TwoHop_ExactBytes() public {
        registry.addToken(address(token), WETH, 500, 3000, _poolStableWeth(500), _poolWethToken(3000));

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
        registry.addToken(address(token), address(0), 500, 0, _poolStableToken(500), address(0));

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
        registry.addToken(address(token), address(0), 500, 0, _poolStableToken(500), address(0));

        registry.setRoute(address(token), WETH, 100, 3000, _poolStableWeth(100), _poolWethToken(3000));

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
        address poolIn = _poolStableToken(500);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.addToken(address(token), address(0), 0, 0, poolIn, address(0));
    }

    function test_AddToken_RevertsInvalidRoute_IntermediateWithoutFeeOut() public {
        address poolIn = _poolStableWeth(500);
        address poolOut = _poolWethToken(3000);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.addToken(address(token), WETH, 500, 0, poolIn, poolOut);
    }

    function test_AddToken_RevertsPoolMismatch_WrongPair() public {
        // Declares a direct STABLE↔token route but hands a WETH↔token pool.
        address wrong = _poolWethToken(500);
        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.PoolMismatch.selector, wrong));
        registry.addToken(address(token), address(0), 500, 0, wrong, address(0));
    }

    function test_AddToken_RevertsPoolMismatch_WrongFee() public {
        // Pool pairs the right tokens but at fee 3000 while the route declares 500.
        address wrongFee = _poolStableToken(3000);
        vm.expectRevert(abi.encodeWithSelector(StockTokenRegistry.PoolMismatch.selector, wrongFee));
        registry.addToken(address(token), address(0), 500, 0, wrongFee, address(0));
    }

    function test_SetRoute_RevertsInvalidRoute_FeeInZero() public {
        registry.addToken(address(token), address(0), 500, 0, _poolStableToken(500), address(0));
        address poolIn = _poolStableToken(500);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.setRoute(address(token), address(0), 0, 0, poolIn, address(0));
    }

    function test_SetRoute_RevertsInvalidRoute_IntermediateWithoutFeeOut() public {
        registry.addToken(address(token), address(0), 500, 0, _poolStableToken(500), address(0));
        address poolIn = _poolStableWeth(500);
        address poolOut = _poolWethToken(3000);
        vm.expectRevert(StockTokenRegistry.InvalidRoute.selector);
        registry.setRoute(address(token), WETH, 500, 0, poolIn, poolOut);
    }
}
