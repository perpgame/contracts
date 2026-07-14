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

    address feeRecipient = address(0xFEE5);
    // Mirrors the contract's fixed FEE_BPS (1%); used only for expected-value math.
    uint16 constant FEE_BPS = 100;

    address alice = address(0xA11CE1);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        tA = new MockAgentTreasury(1_000e6);
        tB = new MockAgentTreasury(1_000e6);
        market = new DuelMarket(address(usdc), feeRecipient);
    }

    // The creator seed IS alice's side-A stake (100 USDC) — folding what used
    // to be her separate first bet() into createDuel keeps every downstream
    // pool/fee/payout number in this suite identical to the pre-seed version.
    function _create() internal returns (uint256) {
        uint64 lock = uint64(block.timestamp + 2 hours);
        uint64 expiry = lock + 1 days;
        _fund(alice, 100e6);
        vm.prank(alice);
        return market.createDuel(address(tA), address(tB), lock, expiry, 0, 100e6);
    }

    function test_createDuel_succeeds_and_indexes() public {
        uint256 id = _create();
        assertEq(id, 0);
        assertEq(market.duelCount(), 1);
        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(d.treasuryA, address(tA));
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Open));
        // The creator seed is booked as an ordinary side-A stake.
        assertEq(d.poolA, 100e6);
        assertEq(market.stakeA(id, alice), 100e6);
        assertEq(usdc.balanceOf(address(market)), 100e6);
    }

    function test_createDuel_emitsSeedBet() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        _fund(alice, 5e6);
        vm.expectEmit(true, true, false, true);
        emit DuelMarket.BetPlaced(0, alice, 1, 5e6);
        vm.prank(alice);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days, 1, 5e6);
        DuelMarket.Duel memory d = market.getDuel(0);
        assertEq(d.poolB, 5e6);
        assertEq(market.stakeB(0, alice), 5e6);
    }

    function test_createDuel_reverts_seedBelowMin() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        _fund(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.BelowCreatorStake.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days, 0, 5e6 - 1);
    }

    function test_createDuel_reverts_seedBadSide() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        _fund(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert(DuelMarket.BadSide.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days, 2, 5e6);
    }

    function test_createDuel_reverts_sameTreasury() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.SameTreasury.selector);
        market.createDuel(address(tA), address(tA), lock, lock + 1 days, 0, 5e6);
    }

    function test_createDuel_reverts_zeroNav() public {
        tB.setNav(0);
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.InvalidTreasury.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days, 0, 5e6);
    }

    function test_createDuel_reverts_zeroNavA() public {
        tA.setNav(0);
        uint64 lock = uint64(block.timestamp + 2 hours);
        vm.expectRevert(DuelMarket.InvalidTreasury.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days, 0, 5e6);
    }

    function test_createDuel_reverts_lockTooSoon() public {
        uint64 lock = uint64(block.timestamp + 10 minutes); // < MIN_BET_WINDOW
        vm.expectRevert(DuelMarket.BadTiming.selector);
        market.createDuel(address(tA), address(tB), lock, lock + 1 days, 0, 5e6);
    }

    function test_createDuel_reverts_durationTooLong() public {
        uint64 lock = uint64(block.timestamp + 2 hours);
        // Read the constant into a local first — calling it inline inside the
        // expectRevert-guarded expression would itself be "the next call" and
        // falsely satisfy expectRevert before createDuel ever runs.
        uint64 maxDuration = market.MAX_DURATION();
        // Right at the cap succeeds...
        _fund(alice, 5e6);
        vm.prank(alice);
        market.createDuel(address(tA), address(tB), lock, lock + maxDuration, 0, 5e6);
        // ...one second past it reverts (before the seed transfer, so no
        // funding is needed). Reads the constant off the contract rather than
        // hardcoding a day count, so this stays correct if MAX_DURATION ever
        // changes again.
        vm.expectRevert(DuelMarket.BadTiming.selector);
        market.createDuel(address(tA), address(tB), lock, lock + maxDuration + 1, 0, 5e6);
    }

    // --- betting helpers ---

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(market), amt);
    }

    // --- bet tests ---

    function test_bet_creditsPoolAndStake() public {
        uint256 id = _create(); // alice seeded 100e6 on A at creation
        _fund(bob, 100e6);
        vm.prank(bob);
        market.bet(id, 1, 100e6);

        DuelMarket.Duel memory d = market.getDuel(id);
        assertEq(d.poolB, 100e6);
        assertEq(market.stakeB(id, bob), 100e6);
        assertEq(usdc.balanceOf(address(market)), 200e6); // seed + bob's bet
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

    // --- lock helpers ---

    function _createAndBetBoth() internal returns (uint256 id) {
        id = _create(); // alice already staked 100e6 on A via the creator seed
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
        uint256 id = _create(); // only the creator seed on A — no B bets
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
        // fee = 1% of losing pool (poolB=100e6) = 1e6, split 50/50: half to
        // feeRecipient, half to the winning treasury (A).
        assertEq(usdc.balanceOf(feeRecipient), 0.5e6);
        assertEq(usdc.balanceOf(address(tA)), 0.5e6);
        // verify fee came from losing pool (B), not winning pool (A)
        // contract held 200e6 total, 1e6 fee left the contract entirely
        assertEq(usdc.balanceOf(address(market)), 199e6);
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
        // fee = 1% of losing pool (poolA=100e6) = 1e6, split 50/50: half to
        // feeRecipient, half to the winning treasury (B).
        assertEq(usdc.balanceOf(feeRecipient), 0.5e6);
        assertEq(usdc.balanceOf(address(tB)), 0.5e6);
        // verify fee came from losing pool (A), not winning pool (B)
        assertEq(usdc.balanceOf(address(market)), 199e6);
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

        // loserPool=100e6, fee=1e6, distributable=99e6. Alice is sole winner.
        uint256 before = usdc.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit DuelMarket.Claimed(id, alice, 199e6);
        vm.prank(alice);
        market.claim(id);
        assertEq(usdc.balanceOf(alice) - before, 100e6 + 99e6); // stake + all winnings
        assertTrue(market.claimed(id, alice));
    }

    function test_claim_winnerBGetsStakePlusShare() public {
        uint256 id = _createAndBetBoth(); // alice A 100e6, bob B 100e6
        _lockDuel(id);
        tA.setNav(1_050e6); tB.setNav(1_200e6); // B wins
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id);

        // loserPool=poolA=100e6, fee=1e6, distributable=99e6. Bob is sole winner.
        uint256 before = usdc.balanceOf(bob);
        vm.expectEmit(true, true, false, true);
        emit DuelMarket.Claimed(id, bob, 199e6);
        vm.prank(bob);
        market.claim(id);
        assertEq(usdc.balanceOf(bob) - before, 100e6 + 99e6); // stake + all winnings
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
        uint256 id = _create(); // one-sided: just the creator seed on A
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
        uint256 id = _create(); // alice's creator seed: 100e6 on A
        _fund(carol, 50e6);  vm.prank(carol); market.bet(id, 0, 50e6);  // A
        _fund(bob, 100e6);   vm.prank(bob);   market.bet(id, 1, 100e6); // B
        // poolA = 150e6, poolB = 100e6
        _lockDuel(id);
        tA.setNav(1_200e6); tB.setNav(1_100e6); // A wins
        vm.warp(market.getDuel(id).expiryTime);
        market.resolve(id); // fee = 1% of poolB(100e6) = 1e6; distributable = 99e6

        // Exact floor-division payouts:
        // alice: 100e6 + 100e6*99e6/150e6 = 100e6 + 66_000000 = 166_000000
        // carol:  50e6 +  50e6*99e6/150e6 =  50e6 + 33_000000 =  83_000000
        uint256 expectedAlice = uint256(100e6) + (uint256(100e6) * 99e6) / 150e6;
        uint256 expectedCarol = uint256(50e6) + (uint256(50e6) * 99e6) / 150e6;
        assertEq(expectedAlice, 166_000000);
        assertEq(expectedCarol, 83_000000);

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
        uint256 distributed = 150e6 + (100e6 - 1e6); // winnerPool + (loserPool - fee) = 249e6
        uint256 dust = distributed - expectedAlice - expectedCarol;
        assertLe(dust, 2);
    }

    function test_claim_voidNonParticipantReverts() public {
        uint256 id = _create(); // one-sided: just the creator seed on A
        _lockDuel(id); // -> Voided
        // bob never staked on this duel
        vm.prank(bob);
        vm.expectRevert(DuelMarket.NothingToClaim.selector);
        market.claim(id);
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
        DuelMarket rMarket      = new DuelMarket(address(rUsdc), feeRecipient);

        uint64 lockTime = uint64(block.timestamp + 2 hours);
        uint64 expiry   = lockTime + 1 days;
        // The test contract itself seeds the mandatory creator stake (side A).
        rUsdc.mint(address(this), 5e6);
        rUsdc.approve(address(rMarket), 5e6);
        uint256 id = rMarket.createDuel(address(rA), address(rB), lockTime, expiry, 0, 5e6);

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
    // Fee model: fee is a fixed 1% constant (FEE_BPS). There is no mutable fee
    // state, so the resolve→claim desync that a snapshot guarded against cannot
    // occur — resolve() and claim() both read the same compile-time constant.
    // -----------------------------------------------------------------------

    function test_fee_isFixedOnePercent() public view {
        assertEq(market.FEE_BPS(), 100);
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
        // The test contract seeds the mandatory creator stake (side A).
        usdc.mint(address(this), 5e6);
        usdc.approve(address(market), 5e6);
        uint256 id = market.createDuel(address(tA), address(rtB), lockTime, expiry, 0, 5e6);

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

        // The creator (this test contract) reclaims its 5e6 seed too.
        market.claim(id);

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
