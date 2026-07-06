// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DuelMarket} from "../src/DuelMarket.sol";
import {MockAgentTreasury} from "./mocks/MockAgentTreasury.sol";
import {MockRevertingTreasury} from "./mocks/MockRevertingTreasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockReentrantUSDC, IReentrantReceiver} from "./mocks/MockReentrantUSDC.sol";

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

    function test_claim_multipleWinnersProRata() public {
        address carol = address(0xCA401);
        uint256 id = _create();
        _fund(alice, 100e6); vm.prank(alice); market.bet(id, 0, 100e6); // A
        _fund(carol, 50e6);  vm.prank(carol); market.bet(id, 0, 50e6);  // A
        _fund(bob, 100e6);   vm.prank(bob);   market.bet(id, 1, 100e6); // B
        // poolA = 150e6, poolB = 100e6
        _lockDuel(id);
        tA.setNav(1_200e6); tB.setNav(1_100e6); // A wins
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id); // fee = 2% of poolB(100e6) = 2e6; distributable = 98e6

        // Exact floor-division payouts:
        // alice: 100e6 + 100e6*98e6/150e6 = 100e6 + 65_333333 = 165_333333
        // carol:  50e6 +  50e6*98e6/150e6 =  50e6 + 32_666666 =  82_666666
        uint256 expectedAlice = uint256(100e6) + (uint256(100e6) * 98e6) / 150e6;
        uint256 expectedCarol = uint256(50e6) + (uint256(50e6) * 98e6) / 150e6;
        assertEq(expectedAlice, 165_333333);
        assertEq(expectedCarol, 82_666666);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); market.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedAlice);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol); market.claim(id);
        assertEq(usdc.balanceOf(carol) - carolBefore, expectedCarol);

        // bob (loser) gets nothing
        vm.prank(bob);
        vm.expectRevert(DuelMarket.NothingToClaim.selector);
        market.claim(id);

        // Conservation: winnerPool + (loserPool - fee) - payouts is only dust (<= #winners wei)
        uint256 distributed = 150e6 + (100e6 - 2e6); // winnerPool + (loserPool - fee) = 248e6
        uint256 dust = distributed - expectedAlice - expectedCarol;
        assertLe(dust, 2);
    }

    function test_claim_voidNonParticipantReverts() public {
        uint256 id = _create();
        _fund(alice, 100e6); vm.prank(alice); market.bet(id, 0, 100e6); // one-sided
        _lockDuel(id); // -> Voided
        // bob never staked on this duel
        vm.prank(bob);
        vm.expectRevert(DuelMarket.NothingToClaim.selector);
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

    // -----------------------------------------------------------------------
    // Reentrancy guard tests
    // -----------------------------------------------------------------------
    //
    // Approach: genuine malicious-token reentrancy.
    //
    // MockUSDC is a plain OZ ERC20 with no transfer hook, so it cannot be used
    // to trigger a reentrant call-back. Instead we deploy MockReentrantUSDC,
    // which overrides `_update` to call `IReentrantReceiver(to).onReceive()`
    // when the receiver is armed. A `ReentrantClaimReceiver` contract receives
    // USDC from the market and immediately tries to call `market.claim(id)`
    // again from inside `onReceive`.
    //
    // The test proves both layers of the belt-and-suspenders defence:
    //   Layer 1 — nonReentrant:  The reentrant call enters a new `claim` frame
    //             while the first `claim` is still executing. OZ ReentrancyGuard
    //             fires `ReentrancyGuardReentrantCall` and reverts it.
    //   Layer 2 — checks-effects: Even if the guard were absent, `claimed` is
    //             set to `true` BEFORE `safeTransfer`, so a second call would
    //             hit `AlreadyClaimed` and still revert.
    //
    // We assert that `onReceive` records a revert selector (either of the two
    // above) so the test fails if neither guard fires.

    function test_claim_cannotDoubleClaim_reentrancyGuarded() public {
        // --- setup: fresh market with the malicious token ---
        MockReentrantUSDC rUsdc = new MockReentrantUSDC();
        MockAgentTreasury rA    = new MockAgentTreasury(1_000e6);
        MockAgentTreasury rB    = new MockAgentTreasury(1_000e6);
        DuelMarket rMarket      = new DuelMarket(address(rUsdc), feeRecipient, FEE_BPS, owner);

        uint64 lockTime = uint64(block.timestamp + 2 hours);
        uint64 expiry   = lockTime + 1 days;
        uint256 id      = rMarket.createDuel(address(rA), address(rB), lockTime, expiry);

        // Deploy the reentrant receiver contract and fund it via the token
        ReentrantClaimReceiver attacker = new ReentrantClaimReceiver(rMarket, id);

        uint128 stake = 100e6;
        rUsdc.mint(address(attacker), stake);
        // attacker approves market
        vm.prank(address(attacker));
        rUsdc.approve(address(rMarket), stake);

        // Also fund bob on the other side so the duel is not voided
        rUsdc.mint(bob, stake);
        vm.prank(bob);
        rUsdc.approve(address(rMarket), stake);

        // attacker bets on side A
        vm.prank(address(attacker));
        rMarket.bet(id, 0, stake);
        // bob bets on side B
        vm.prank(bob);
        rMarket.bet(id, 1, stake);

        // lock + resolve with A winning
        vm.warp(lockTime);
        rMarket.lock(id);
        rA.setNav(1_200e6); // A wins
        vm.warp(expiry);
        rMarket.resolve(id);

        // Arm the reentrant hook: when rUsdc transfers to attacker, it fires onReceive
        rUsdc.arm(address(attacker));

        // The first claim should succeed; the reentrant second claim inside onReceive
        // must revert. ReentrantClaimReceiver stores the revert data for inspection.
        vm.prank(address(attacker));
        rMarket.claim(id);

        // The attacker contract's reentrant call was blocked
        assertTrue(attacker.reentrancyCaught(), "reentrancy was NOT caught - guard missing");

        // Verify the revert was one of the two expected guards
        bytes4 revertSelector = attacker.caughtSelector();
        bool isNonReentrantGuard = revertSelector == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        bool isAlreadyClaimed    = revertSelector == DuelMarket.AlreadyClaimed.selector;
        assertTrue(
            isNonReentrantGuard || isAlreadyClaimed,
            "unexpected revert selector on reentrant claim"
        );

        // The attacker received their legitimate payout (first claim succeeded)
        assertGt(rUsdc.balanceOf(address(attacker)), 0, "attacker received no payout");

        // The attacker did NOT receive a second payout (reentrancy was blocked)
        assertTrue(rMarket.claimed(id, address(attacker)), "claim flag not set");
    }

    // -----------------------------------------------------------------------
    // F1 — fee snapshot: claim must use the fee bps locked in at resolve time,
    //      not the live feeBps that may have been changed afterwards.
    // -----------------------------------------------------------------------

    /// @dev RED until feeBpsSnapshot field + claim fix applied.
    function test_claim_usesFeeSnapshot_notLiveFeeBps() public {
        // Setup: poolA = poolB = 100e6, resolve at FEE_BPS = 200 (2%)
        uint256 id = _createAndBetBoth(); // alice side A 100e6, bob side B 100e6
        _lockDuel(id);
        tA.setNav(1_200e6); tB.setNav(1_100e6); // A wins
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);

        // fee at resolve: 2% of loserPool(100e6) = 2e6 already transferred out
        uint256 feeRecipientAfterResolve = usdc.balanceOf(feeRecipient);
        assertEq(feeRecipientAfterResolve, 2e6, "fee from resolve should be 2e6");

        // Now owner changes feeBps to 10% AFTER resolve
        vm.prank(owner);
        market.setFeeConfig(1000, feeRecipient);

        // Sole winner alice claims — payout must be computed at snapshot (200 bps), not live (1000 bps)
        // Expected: stake(100e6) + (stake * (loserPool - fee_at_snapshot)) / poolA
        //         = 100e6 + (100e6 * (100e6 - 2e6)) / 100e6
        //         = 100e6 + 98e6 = 198e6
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim(id); // must not revert
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;
        assertEq(alicePayout, 198e6, "payout must use snapshot fee (2%), not live fee (10%)");

        // Contract should be solvent: 200e6 deposited - 2e6 fee out - 198e6 to alice = 0 remaining
        assertEq(usdc.balanceOf(address(market)), 0, "contract should be solvent after claim");

        // ---- Second direction: resolve at 200, then setFeeConfig(0) — also no insolvency ----
        // Fresh duel
        address dave = address(0xDA4E);
        address eve  = address(0xE4E);
        uint256 id2 = _create();
        _fund(dave, 100e6); vm.prank(dave); market.bet(id2, 0, 100e6);
        _fund(eve, 100e6);  vm.prank(eve);  market.bet(id2, 1, 100e6);
        _lockDuel(id2);
        tA.setNav(1_500e6); tB.setNav(1_100e6); // A wins again
        vm.warp(market.getDuel(id2).expiryTime);

        // reset live feeBps back to 200 for resolve
        vm.prank(owner);
        market.setFeeConfig(200, feeRecipient);
        market.resolve(id2);

        // now set fee to 0 after resolve
        vm.prank(owner);
        market.setFeeConfig(0, feeRecipient);

        // dave claims — should use snapshot of 200 bps, not 0
        uint256 daveBefore = usdc.balanceOf(dave);
        vm.prank(dave);
        market.claim(id2);
        uint256 davePayout = usdc.balanceOf(dave) - daveBefore;
        assertEq(davePayout, 198e6, "payout must use snapshot fee (2%), not live 0%");
    }

    // -----------------------------------------------------------------------
    // F2 — resolve must void (not revert forever) when nav() reverts mid-call.
    // -----------------------------------------------------------------------

    /// @dev RED until try/catch nav void applied in resolve().
    function test_resolve_voidsWhenNavReverts() public {
        // Use MockRevertingTreasury for side B so we can arm it mid-test
        MockRevertingTreasury rtB = new MockRevertingTreasury(1_000e6);

        uint64 lockTime = uint64(block.timestamp + 2 hours);
        uint64 expiry   = lockTime + 1 days;
        uint256 id = market.createDuel(address(tA), address(rtB), lockTime, expiry);

        _fund(alice, 100e6); vm.prank(alice); market.bet(id, 0, 100e6);
        _fund(bob, 100e6);   vm.prank(bob);   market.bet(id, 1, 100e6);

        // Lock succeeds — both navs are healthy
        vm.warp(lockTime);
        market.lock(id);
        assertEq(uint8(market.getDuel(id).status), uint8(DuelMarket.Status.Locked));

        // Arm the reverting treasury AFTER lock
        rtB.setReverting(true);

        // Warp past expiry and call resolve — must NOT revert, must void instead
        vm.warp(expiry);
        vm.expectEmit(true, false, false, false);
        emit DuelMarket.DuelVoided(id);
        market.resolve(id); // must succeed (not revert)

        assertEq(uint8(market.getDuel(id).status), uint8(DuelMarket.Status.Voided),
            "status should be Voided when nav() reverts");

        // Both bettors reclaim full stakes (void path in claim)
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6, "alice stake refund");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim(id);
        assertEq(usdc.balanceOf(bob) - bobBefore, 100e6, "bob stake refund");

        // Contract fully drained, no fee taken on void
        assertEq(usdc.balanceOf(address(market)), 0, "contract drained after void refunds");
    }
}

// ---------------------------------------------------------------------------
// Helper: reentrant receiver contract used in test_claim_cannotDoubleClaim_reentrancyGuarded
// ---------------------------------------------------------------------------

/// @notice A contract that bets on side A and, when it receives USDC from
///         the market's claim() payout, immediately calls claim() again.
///         The reentrant call must revert; we record the selector for inspection.
contract ReentrantClaimReceiver is IReentrantReceiver {
    DuelMarket public immutable market;
    uint256    public immutable duelId;

    bool   public reentrancyCaught;
    bytes4 public caughtSelector;

    constructor(DuelMarket market_, uint256 duelId_) {
        market = market_;
        duelId = duelId_;
    }

    /// @dev Called by MockReentrantUSDC._update during the first claim's safeTransfer.
    function onReceive() external override {
        // Attempt to re-enter claim(). This must revert.
        try market.claim(duelId) {
            // If we reach here, neither guard fired — the test will fail.
            reentrancyCaught = false;
        } catch (bytes memory reason) {
            reentrancyCaught = true;
            if (reason.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(reason, 32)) }
                caughtSelector = sel;
            }
        }
    }
}
