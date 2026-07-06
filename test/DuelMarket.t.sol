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

    function test_bet_reverts_whenPaused() public {
        uint256 id = _create();
        vm.prank(owner);
        market.setPaused(true);
        _fund(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.IsPaused.selector);
        market.bet(id, 0, 100e6);
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

    // --- lock helpers ---

    function _createAndBetBoth() internal returns (uint256 id) {
        id = _create();
        _fund(alice, 100e6); vm.prank(alice); market.bet(id, 0, 100e6);
        _fund(bob, 100e6);   vm.prank(bob);   market.bet(id, 1, 100e6);
    }

    // --- lock tests ---

    function test_lock_snapshotsNav() public {
        uint256 id = _createAndBetBoth();
        DuelMarket.Duel memory d0 = market.getDuel(id);
        vm.warp(d0.lockTime);
        vm.expectEmit(true, false, false, true);
        emit DuelMarket.DuelLocked(id, 1_000e6, 1_000e6);
        market.lock(id);
        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Locked));
        assertEq(d.navStartA, 1_000e6);
        assertEq(d.navStartB, 1_000e6);
    }

    function test_lock_voidsWhenOneSided() public {
        uint256 id = _create();
        _fund(alice, 100e6); vm.prank(alice); market.bet(id, 0, 100e6); // only A
        DuelMarket.Duel memory d0 = market.getDuel(id);
        vm.warp(d0.lockTime);
        vm.expectEmit(true, false, false, false);
        emit DuelMarket.DuelVoided(id);
        market.lock(id);
        assertEq(uint8(market.getDuel(id).status), uint8(DuelMarket.Status.Voided));
    }

    function test_lock_voidsWhenZeroNav() public {
        uint256 id = _createAndBetBoth();
        tA.setNav(0); // treasury A goes to zero nav after betting
        DuelMarket.Duel memory d0 = market.getDuel(id);
        vm.warp(d0.lockTime);
        vm.expectEmit(true, false, false, false);
        emit DuelMarket.DuelVoided(id);
        market.lock(id);
        assertEq(uint8(market.getDuel(id).status), uint8(DuelMarket.Status.Voided));
    }

    function test_lock_reverts_tooEarly() public {
        uint256 id = _createAndBetBoth();
        vm.expectRevert(DuelMarket.TooEarly.selector);
        market.lock(id);
    }

    function test_lock_reverts_wrongStatus_ifAlreadyLocked() public {
        uint256 id = _createAndBetBoth();
        vm.warp(market.getDuel(id).lockTime);
        market.lock(id);
        vm.expectRevert(DuelMarket.WrongStatus.selector);
        market.lock(id);
    }

    // --- resolve helpers ---

    function _lockDuel(uint256 id) internal {
        vm.warp(market.getDuel(id).lockTime);
        market.lock(id);
    }

    // --- resolve tests ---

    function test_resolve_A_wins_and_takesFee() public {
        uint256 id = _createAndBetBoth();  // poolA=100e6, poolB=100e6, navs=1000e6
        _lockDuel(id);
        tA.setNav(1_200e6);   // +20%
        tB.setNav(1_100e6);   // +10%
        vm.warp(market.getDuel(id).expiryTime);

        vm.expectEmit(true, false, false, true);
        emit DuelMarket.DuelResolved(id, 0, 1_200e6, 1_100e6);
        market.resolve(id);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Resolved));
        assertEq(d.winner, 0);
        // fee = 2% of losing pool (poolB=100e6) = 2e6
        assertEq(usdc.balanceOf(feeRecipient), 2e6);
        // verify fee came from losing pool (B), not winning pool (A)
        // contract held 200e6 total, feeRecipient gets 2e6 from poolB
        assertEq(usdc.balanceOf(address(market)), 198e6);
    }

    function test_resolve_B_wins_and_takesFee() public {
        uint256 id = _createAndBetBoth();  // poolA=100e6, poolB=100e6, navs=1000e6
        _lockDuel(id);
        tA.setNav(1_050e6);   // +5%
        tB.setNav(1_200e6);   // +20%
        vm.warp(market.getDuel(id).expiryTime);

        vm.expectEmit(true, false, false, true);
        emit DuelMarket.DuelResolved(id, 1, 1_050e6, 1_200e6);
        market.resolve(id);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Resolved));
        assertEq(d.winner, 1);
        // fee = 2% of losing pool (poolA=100e6) = 2e6
        assertEq(usdc.balanceOf(feeRecipient), 2e6);
        // verify fee came from losing pool (A), not winning pool (B)
        assertEq(usdc.balanceOf(address(market)), 198e6);
    }

    function test_resolve_tie_noFee() public {
        uint256 id = _createAndBetBoth();
        _lockDuel(id);
        tA.setNav(1_100e6);
        tB.setNav(1_100e6);   // equal PnL%
        vm.warp(market.getDuel(id).expiryTime);

        vm.expectEmit(true, false, false, true);
        emit DuelMarket.DuelResolved(id, 2, 1_100e6, 1_100e6);
        market.resolve(id);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Resolved));
        assertEq(d.winner, 2);
        assertEq(d.navEndA, 1_100e6);
        assertEq(d.navEndB, 1_100e6);
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_resolve_reverts_tooEarly() public {
        uint256 id = _createAndBetBoth();
        _lockDuel(id);
        vm.expectRevert(DuelMarket.TooEarly.selector);
        market.resolve(id);
    }

    function test_resolve_reverts_ifNotLocked() public {
        uint256 id = _createAndBetBoth();
        vm.warp(market.getDuel(id).expiryTime);
        vm.expectRevert(DuelMarket.WrongStatus.selector);
        market.resolve(id);
    }

    // --- claim tests ---

    function test_claim_winnerGetsStakePlusShare() public {
        uint256 id = _createAndBetBoth(); // alice A 100e6, bob B 100e6
        _lockDuel(id);
        tA.setNav(1_200e6); tB.setNav(1_100e6); // A wins
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);

        // loserPool=100e6, fee=2e6, distributable=98e6. Alice is sole winner.
        uint256 before = usdc.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit DuelMarket.Claimed(id, alice, 198e6);
        vm.prank(alice);
        market.claim(id);
        assertEq(usdc.balanceOf(alice) - before, 100e6 + 98e6); // stake + all winnings
        assertTrue(market.claimed(id, alice));
    }

    function test_claim_winnerBGetsStakePlusShare() public {
        uint256 id = _createAndBetBoth(); // alice A 100e6, bob B 100e6
        _lockDuel(id);
        tA.setNav(1_050e6); tB.setNav(1_200e6); // B wins
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);

        // loserPool=poolA=100e6, fee=2e6, distributable=98e6. Bob is sole winner.
        uint256 before = usdc.balanceOf(bob);
        vm.expectEmit(true, true, false, true);
        emit DuelMarket.Claimed(id, bob, 198e6);
        vm.prank(bob);
        market.claim(id);
        assertEq(usdc.balanceOf(bob) - before, 100e6 + 98e6); // stake + all winnings
        assertTrue(market.claimed(id, bob));
    }

    function test_claim_loserGetsNothing() public {
        uint256 id = _createAndBetBoth();
        _lockDuel(id);
        tA.setNav(1_200e6); tB.setNav(1_100e6); // A wins, bob (B) loses
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);
        vm.prank(bob);
        vm.expectRevert(DuelMarket.NothingToClaim.selector);
        market.claim(id);
    }

    function test_claim_twiceReverts() public {
        uint256 id = _createAndBetBoth();
        _lockDuel(id);
        tA.setNav(1_200e6); tB.setNav(1_100e6);
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);
        vm.prank(alice); market.claim(id);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.AlreadyClaimed.selector);
        market.claim(id);
    }

    function test_claim_voidRefundsStake() public {
        uint256 id = _create();
        _fund(alice, 100e6); vm.prank(alice); market.bet(id, 0, 100e6); // one-sided
        _lockDuel(id); // -> Voided
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); market.claim(id);
        assertEq(usdc.balanceOf(alice) - before, 100e6);
        assertTrue(market.claimed(id, alice));
    }

    function test_claim_tieRefundsStake() public {
        uint256 id = _createAndBetBoth();
        _lockDuel(id);
        tA.setNav(1_100e6); tB.setNav(1_100e6); // tie
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob); market.claim(id);
        assertEq(usdc.balanceOf(bob) - before, 100e6);
        assertTrue(market.claimed(id, bob));
    }

    function test_claim_beforeResolveReverts() public {
        uint256 id = _createAndBetBoth();
        _lockDuel(id);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.WrongStatus.selector);
        market.claim(id);
    }

    function test_betWithPermit_toleratesStalePermit() public {
        uint256 id = _create();
        usdc.mint(alice, 50e6);

        // Build + sign an EIP-2612 permit for the market spending 50e6.
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

        // Front-run: consume the nonce directly so the signature is now stale.
        usdc.permit(alice, address(market), 50e6, deadline, v, r, s);

        // Alice separately grants allowance the normal way.
        vm.prank(alice);
        usdc.approve(address(market), 50e6);

        // betWithPermit with the STALE signature must still land: the permit
        // reverts inside the try/catch and the bet uses the existing allowance.
        vm.prank(alice);
        market.betWithPermit(id, 0, 50e6, deadline, v, r, s);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(d.poolA, 50e6);
        assertEq(market.stakeA(id, alice), 50e6);
        assertEq(usdc.balanceOf(address(market)), 50e6);
    }
}
