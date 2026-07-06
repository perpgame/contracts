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

    // betting fixtures — declared here so setUp can reference alicePk
    uint256 alicePk = 0xA11CE1; // distinct from owner (0xA11CE)
    address alice;              // set in setUp via vm.addr(alicePk)
    address bob = address(0xB0B);

    function setUp() public {
        alice = vm.addr(alicePk); // derive alice's address from known private key
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

    function test_createDuel_reverts_zeroNavA() public {
        tA.setNav(0);
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.InvalidTreasury.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days);
    }

    function test_createDuel_reverts_whenPaused() public {
        vm.prank(owner);
        market.setPaused(true);
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.IsPaused.selector);
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

    // --- betting helpers ---

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(market), amt);
    }

    // --- bet tests ---

    function test_bet_creditsPoolAndStake() public {
        uint256 id = _create();
        _fund(alice, 100e6);
        vm.prank(alice);
        market.bet(id, 0, 100e6);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(d.poolA, 100e6);
        assertEq(market.stakeA(id, alice), 100e6);
        assertEq(usdc.balanceOf(address(market)), 100e6);
    }

    function test_bet_reverts_belowMin() public {
        uint256 id = _create();
        _fund(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.BelowMinBet.selector);
        market.bet(id, 0, 1e6 - 1);
    }

    function test_bet_reverts_badSide() public {
        uint256 id = _create();
        _fund(alice, 10e6);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.BadSide.selector);
        market.bet(id, 2, 10e6);
    }

    function test_bet_reverts_afterLockTime() public {
        uint256 id = _create();
        _fund(alice, 10e6);
        DuelMarket.Duel memory d = market.getDuel(id);
        vm.warp(d.lockTime);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.BettingClosed.selector);
        market.bet(id, 0, 10e6);
    }

    function test_betWithPermit_singleTx() public {
        uint256 id = _create();
        // Mint directly (no prior approve needed — permit will grant allowance)
        usdc.mint(alice, 50e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(market),
            uint256(50e6),
            usdc.nonces(alice),
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.prank(alice);
        market.betWithPermit(id, 1, 50e6, deadline, v, r, s);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(d.poolB, 50e6);
        assertEq(market.stakeB(id, alice), 50e6);
    }
}
