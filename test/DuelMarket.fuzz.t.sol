// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DuelMarket} from "../src/DuelMarket.sol";
import {MockAgentTreasury} from "./mocks/MockAgentTreasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title DuelMarketFuzzTest
/// @notice Conservation + solvency fuzz over arbitrary stakes and nav outcomes.
///
/// Three helpers cover all three outcome branches (A wins, B wins, tie) so the
/// fuzz engine can drive the outcome by varying navEndA / navEndB independently.
///
/// Conservation invariant being tested:
///   feeRecipient_balance + sum(winner_payouts) + dust == totalPot
///   where dust >= 0  (contract never goes insolvent / reverts on final claim)
///   and   dust <= number_of_winners (floor-division loses at most 1 wei/winner)
///
/// Post-resolve balance invariant:
///   usdc.balanceOf(market) == totalPot - fee
///   (all remaining USDC stays in the contract until winners claim)
contract DuelMarketFuzzTest is Test {
    // navStart fixed for both treasuries in every test scenario
    uint256 constant NAV_START = 1_000e6;
    uint16  constant FEE_BPS   = 100;     // 1% of losing pool (mirrors contract FEE_BPS)
    address constant FEE_ADDR  = address(0xFEE5);

    // -----------------------------------------------------------------------
    // Scenario A: side A wins (navEndA grows more than navEndB)
    // -----------------------------------------------------------------------

    /// @notice Fuzz: side A wins. Alice bets on A, Bob bets on B.
    ///
    /// Assertions:
    ///   1. After resolve, market holds exactly totalPot - fee.
    ///   2. Alice's payout is her stake plus her proportional share of (loserPool - fee).
    ///   3. The payout never exceeds what the contract holds — no insolvency revert.
    ///   4. dust = totalPot - fee_paid - alice_payout; 0 <= dust <= 1 (sole winner).
    function testFuzz_conservation_A_wins(
        uint128 aStake,
        uint128 bStake,
        uint64  navEndARaw
    ) public {
        aStake    = uint128(bound(aStake,    1e6, 1e15));
        bStake    = uint128(bound(bStake,    1e6, 1e15));
        // navEndA must produce a strictly higher PnL% than navEndB which stays at NAV_START
        // pnlB = 0 %, so any navEndA > NAV_START means A wins
        uint256 navEndA = bound(navEndARaw, NAV_START + 1, 1e15);

        (DuelMarket market, MockUSDC usdc,
         MockAgentTreasury tA, MockAgentTreasury tB) = _deploy();

        uint256 id = _createBetLock(market, usdc, tA, tB, aStake, bStake);

        // Set navs: A wins (B stays at NAV_START => pnlB = 0%)
        tA.setNav(navEndA);
        // tB stays at NAV_START (pnlB = 0%)

        DuelMarket.Duel memory d = market.getDuel(id);
        vm.warp(d.expiryTime);
        market.resolve(id);

        d = market.getDuel(id);
        assertEq(d.winner, 0, "expected A to win");
        assertEq(uint8(d.status), uint8(DuelMarket.Status.Resolved));

        uint256 totalPot = uint256(aStake) + uint256(bStake);
        uint256 loserPool = uint256(bStake);
        uint256 fee = loserPool * FEE_BPS / 10_000;

        // Invariant 1: after resolve, market holds totalPot - fee (fee already sent)
        assertEq(
            usdc.balanceOf(address(market)),
            totalPot - fee,
            "market balance after resolve != totalPot - fee"
        );
        assertEq(
            usdc.balanceOf(FEE_ADDR),
            fee,
            "feeRecipient balance != fee"
        );

        // Invariant 2: alice can claim without revert (solvency)
        address alice = address(0xA1);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim(id); // must NOT revert
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;

        // Invariant 3: alice received her stake + full distributable (sole winner)
        uint256 distributable = loserPool - fee;
        uint256 expectedPayout = uint256(aStake) + (uint256(aStake) * distributable) / uint256(aStake);
        // with sole winner: expectedPayout = aStake + distributable
        assertEq(alicePayout, expectedPayout, "alice payout != stake + distributable");

        // Invariant 4: dust is non-negative and <= 1 wei (sole winner, floor div)
        uint256 dust = totalPot - fee - alicePayout;
        // dust must not underflow (contract was solvent) — the subtraction above would
        // panic in 0.8.x if alicePayout > totalPot - fee, so reaching here proves solvency
        assertLe(dust, 1, "dust > 1 wei with sole winner");
    }

    // -----------------------------------------------------------------------
    // Scenario B: side B wins (navEndB grows more than navEndA)
    // -----------------------------------------------------------------------

    /// @notice Fuzz: side B wins. Alice bets on A, Bob bets on B.
    ///
    /// Assertions mirror A-wins but the winning pool is B.
    function testFuzz_conservation_B_wins(
        uint128 aStake,
        uint128 bStake,
        uint64  navEndBRaw
    ) public {
        aStake    = uint128(bound(aStake,    1e6, 1e15));
        bStake    = uint128(bound(bStake,    1e6, 1e15));
        // navEndB must produce strictly higher PnL% than navEndA (stays at NAV_START)
        uint256 navEndB = bound(navEndBRaw, NAV_START + 1, 1e15);

        (DuelMarket market, MockUSDC usdc,
         MockAgentTreasury tA, MockAgentTreasury tB) = _deploy();

        uint256 id = _createBetLock(market, usdc, tA, tB, aStake, bStake);

        // tA stays at NAV_START (pnlA = 0%), B wins
        tB.setNav(navEndB);

        DuelMarket.Duel memory d = market.getDuel(id);
        vm.warp(d.expiryTime);
        market.resolve(id);

        d = market.getDuel(id);
        assertEq(d.winner, 1, "expected B to win");

        uint256 totalPot    = uint256(aStake) + uint256(bStake);
        uint256 loserPool   = uint256(aStake);
        uint256 fee         = loserPool * FEE_BPS / 10_000;
        uint256 distributable = loserPool - fee;

        // Invariant 1: post-resolve balance
        assertEq(
            usdc.balanceOf(address(market)),
            totalPot - fee,
            "market balance after resolve != totalPot - fee (B wins)"
        );
        assertEq(usdc.balanceOf(FEE_ADDR), fee, "feeRecipient balance != fee (B wins)");

        // Invariant 2: bob can claim without revert (solvency)
        address bob = address(0xB0B);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.claim(id);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;

        // Invariant 3: sole winner gets exactly bStake + distributable
        uint256 expectedPayout = uint256(bStake) + (uint256(bStake) * distributable) / uint256(bStake);
        assertEq(bobPayout, expectedPayout, "bob payout != stake + distributable (B wins)");

        // Invariant 4: dust in [0,1]
        uint256 dust = totalPot - fee - bobPayout;
        assertLe(dust, 1, "dust > 1 wei with sole winner (B wins)");
    }

    // -----------------------------------------------------------------------
    // Scenario C: tie (both navs equal percentage change => winner == 2)
    // -----------------------------------------------------------------------

    /// @notice Fuzz: tie outcome. Both sides get refunds; no fee.
    ///
    /// Assertions:
    ///   1. No fee is sent — feeRecipient balance remains 0.
    ///   2. After resolve, market holds the entire totalPot.
    ///   3. Both alice and bob can claim full refunds without revert.
    ///   4. alice_payout + bob_payout == totalPot (exact, no dust on tie).
    function testFuzz_conservation_tie(
        uint128 aStake,
        uint128 bStake,
        uint64  tieNavRaw
    ) public {
        aStake = uint128(bound(aStake, 1e6, 1e15));
        bStake = uint128(bound(bStake, 1e6, 1e15));
        // Fuzz the shared end-nav across gain / flat / loss relative to NAV_START.
        // Both treasuries get the SAME value => identical PnL% => tie regardless.
        uint256 tieNav = bound(tieNavRaw, 1, 2 * NAV_START);

        (DuelMarket market, MockUSDC usdc,
         MockAgentTreasury tA, MockAgentTreasury tB) = _deploy();

        uint256 id = _createBetLock(market, usdc, tA, tB, aStake, bStake);

        // Both treasuries move to the same (fuzzed) NAV => identical PnL% => tie
        tA.setNav(tieNav);
        tB.setNav(tieNav);

        DuelMarket.Duel memory d = market.getDuel(id);
        vm.warp(d.expiryTime);
        market.resolve(id);

        d = market.getDuel(id);
        assertEq(d.winner, 2, "expected tie");

        uint256 totalPot = uint256(aStake) + uint256(bStake);

        // Invariant 1: no fee on tie
        assertEq(usdc.balanceOf(FEE_ADDR), 0, "fee sent on tie");

        // Invariant 2: market holds full pot after resolve
        assertEq(
            usdc.balanceOf(address(market)),
            totalPot,
            "market does not hold full pot on tie"
        );

        // Invariant 3: alice refund (solvency check — must not revert)
        address alice = address(0xA1);
        address bob   = address(0xB0B);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);

        vm.prank(alice); market.claim(id);
        vm.prank(bob);   market.claim(id);

        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobPayout   = usdc.balanceOf(bob)   - bobBefore;

        // Invariant 4: each claimant gets exactly their stake back
        assertEq(alicePayout, uint256(aStake), "alice tie refund != aStake");
        assertEq(bobPayout,   uint256(bStake), "bob tie refund != bStake");

        // Invariant 5: full conservation — payouts sum to totalPot
        assertEq(alicePayout + bobPayout, totalPot, "tie payouts do not sum to totalPot");
    }

    // -----------------------------------------------------------------------
    // Scenario D: multiple winners — dust bounded by winner count
    // -----------------------------------------------------------------------

    /// @notice Fuzz: two bettors on winning side (A). Tests that dust is
    ///         bounded by the number of winners (2), not just 1.
    ///
    /// Assertions:
    ///   1. Post-resolve balance == totalPot - fee.
    ///   2. Both winners claim without revert (solvency).
    ///   3. fee + alice_payout + carol_payout + dust == totalPot.
    ///   4. dust in [0, 2].
    ///   5. Contract USDC balance after all claims == dust (residual, non-negative).
    function testFuzz_conservation_multipleWinners(
        uint128 aliceStake,
        uint128 carolStake,
        uint128 bStake,
        uint64  navEndARaw
    ) public {
        aliceStake = uint128(bound(aliceStake, 1e6, 1e14));
        carolStake = uint128(bound(carolStake, 1e6, 1e14));
        bStake     = uint128(bound(bStake,     1e6, 1e15));
        uint256 navEndA = bound(navEndARaw, NAV_START + 1, 1e15);

        (DuelMarket market, MockUSDC usdc,
         MockAgentTreasury tA, MockAgentTreasury tB) = _deploy();

        uint64 lockTime = uint64(block.timestamp + 2 hours);
        uint64 expiry   = lockTime + 1 days;
        uint256 id = market.createDuel(address(tA), address(tB), lockTime, expiry);

        address alice = address(0xA1);
        address carol = address(0xCA401);
        address bob   = address(0xB0B);

        usdc.mint(alice, aliceStake); vm.prank(alice); usdc.approve(address(market), aliceStake);
        usdc.mint(carol, carolStake); vm.prank(carol); usdc.approve(address(market), carolStake);
        usdc.mint(bob,   bStake);     vm.prank(bob);   usdc.approve(address(market), bStake);

        vm.prank(alice); market.bet(id, 0, aliceStake);
        vm.prank(carol); market.bet(id, 0, carolStake);
        vm.prank(bob);   market.bet(id, 1, bStake);

        vm.warp(lockTime);
        market.lock(id);

        tA.setNav(navEndA); // A wins; tB stays at NAV_START

        DuelMarket.Duel memory d = market.getDuel(id);
        vm.warp(d.expiryTime);
        market.resolve(id);

        d = market.getDuel(id);
        assertEq(d.winner, 0, "expected A to win in multi-winner scenario");

        uint256 totalPot  = uint256(aliceStake) + uint256(carolStake) + uint256(bStake);
        uint256 loserPool = uint256(bStake);
        uint256 fee       = loserPool * FEE_BPS / 10_000;

        // Invariant 1: post-resolve balance
        assertEq(
            usdc.balanceOf(address(market)),
            totalPot - fee,
            "post-resolve balance mismatch (multi-winner)"
        );

        // Invariant 2: both winners claim without revert
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(alice); market.claim(id);
        vm.prank(carol); market.claim(id);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;
        uint256 carolPayout = usdc.balanceOf(carol) - carolBefore;

        // Invariant 3: each winner's payout is exactly proportional to their stake.
        // This discriminates a correct `s + s*distributable/winnerPool` formula from
        // a broken `s + distributable/winnerPool` (or similar). The expected values
        // floor exactly like the contract, so assertEq is valid.
        uint256 distributable = loserPool - fee;
        uint256 winnerPool    = uint256(aliceStake) + uint256(carolStake);
        uint256 expectedAlice = uint256(aliceStake) + (uint256(aliceStake) * distributable) / winnerPool;
        uint256 expectedCarol = uint256(carolStake) + (uint256(carolStake) * distributable) / winnerPool;
        assertEq(alicePayout, expectedAlice, "alice not proportional");
        assertEq(carolPayout, expectedCarol, "carol not proportional");

        // Invariant 4: dust in [0, 2]
        uint256 paid = alicePayout + carolPayout;
        // Arithmetic will revert (underflow) if paid > totalPot - fee, proving solvency
        uint256 dust = (totalPot - fee) - paid;
        assertLe(dust, 2, "dust > 2 wei with two winners");

        // Invariant 5: contract residual is exactly dust (non-negative by definition)
        assertEq(usdc.balanceOf(address(market)), dust, "contract residual != dust");
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Deploy a fresh DuelMarket + tokens for each fuzz run.
    function _deploy() internal returns (
        DuelMarket market,
        MockUSDC   usdc,
        MockAgentTreasury tA,
        MockAgentTreasury tB
    ) {
        usdc   = new MockUSDC();
        tA     = new MockAgentTreasury(NAV_START);
        tB     = new MockAgentTreasury(NAV_START);
        market = new DuelMarket(address(usdc), FEE_ADDR, address(this));
    }

    /// @dev Create duel, fund alice (A) and bob (B), bet both sides, lock.
    ///      alice = address(0xA1), bob = address(0xB0B).
    function _createBetLock(
        DuelMarket        market,
        MockUSDC          usdc,
        MockAgentTreasury tA,
        MockAgentTreasury tB,
        uint128           aStake,
        uint128           bStake
    ) internal returns (uint256 id) {
        uint64 lockTime = uint64(block.timestamp + 2 hours);
        uint64 expiry   = lockTime + 1 days;
        id = market.createDuel(address(tA), address(tB), lockTime, expiry);

        address alice = address(0xA1);
        address bob   = address(0xB0B);

        usdc.mint(alice, aStake); vm.prank(alice); usdc.approve(address(market), aStake);
        usdc.mint(bob,   bStake); vm.prank(bob);   usdc.approve(address(market), bStake);

        vm.prank(alice); market.bet(id, 0, aStake);
        vm.prank(bob);   market.bet(id, 1, bStake);

        vm.warp(lockTime);
        market.lock(id);
        // Warp back so tA/tB nav can be set before expiry warp in the caller
        // (no warp back needed — caller warps to expiry)
    }
}
