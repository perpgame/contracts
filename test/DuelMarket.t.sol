// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DuelMarket} from "../src/DuelMarket.sol";
import {MockAgentTreasury} from "./mocks/MockAgentTreasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract DuelMarketTest is Test {
    DuelMarket market;
    MockUSDC usdc;
    MockAgentTreasury tA;
    MockAgentTreasury tB;

    address owner = address(0xA11CE);
    address feeRecipient = address(0xFEE5);
    uint16 constant FEE_BPS = 200;

    function setUp() public {
        usdc = new MockUSDC();
        tA = new MockAgentTreasury(1_000e6);
        tB = new MockAgentTreasury(1_000e6);
        market = new DuelMarket(address(usdc), feeRecipient, FEE_BPS, owner);
    }

    function _create() internal returns (uint256) {
        uint64 lock = uint64(block.timestamp + 2 hours);
        uint64 expiry = lock + 1 days;
        return market.createDuel(address(tA), address(tB), lock, expiry);
    }

    function test_createDuel_succeeds_and_indexes() public {
        uint256 id = _create();
        assertEq(id, 0);
        assertEq(market.duelCount(), 1);
        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(d.treasuryA, address(tA));
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Open));
    }

    function test_createDuel_reverts_sameTreasury() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.SameTreasury.selector);
        market.createDuel(address(tA), address(tA), lock, lock + 1 days);
    }

    function test_createDuel_reverts_zeroNav() public {
        tB.setNav(0);
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.InvalidTreasury.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days);
    }

    function test_createDuel_reverts_lockTooSoon() public {
        uint64 lock = uint64(block.timestamp + 10 minutes); // < MIN_BET_WINDOW
        vm.expectRevert(DuelMarket.BadTiming.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days);
    }

    function test_createDuel_reverts_durationTooLong() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.BadTiming.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 91 days);
    }
}
