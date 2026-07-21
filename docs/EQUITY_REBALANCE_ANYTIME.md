# Equity rebalance: 24/7 (decouple from the mint MarketClosed gate)

## Goal / correction
Rebalance must run **any time, including weekends/holidays**, independent of
Chainlink staleness. This restores the original intent in
EQUITY_EXECUTION_PRICING_SPEC.md ("Rebalance — execution-priced, runs 24/7") that
the delivered implementation broke: because `AgentCurve` and the rebalancer both
size off the reverting `nav()`, rebalance currently pauses along with mint when a
feed is stale. Decouple them.

Mint stays strictly Chainlink-anchored and paused-on-stale (UNCHANGED). Redeem is
already 24/7 (UNCHANGED). Only the rebalance path changes.

## Why this is safe to run 24/7 (it's not mint)
- **Authorized-only**: rebalance is the rebalancer two-step (`setTargetPortfolio`
  then execute), callable only by the trusted rebalancer signer — an external
  attacker cannot trigger a rebalance to exploit a manipulated spot.
- **Realized + floored**: every leg swap executes against the live pool with an
  `amountOutMinimum`, so the worst case per swap is bounded by the floor buffer,
  not by the mark used to size it.
- Contrast with mint, which permanently issues shares against a treasury
  valuation — that's why mint must stay Chainlink-gated and this must not.

## Change
Rebalance execution must NOT call the reverting `nav()`/`valueOf`. Introduce a
**staleness-tolerant sizing** used for rebalance only:

- Current per-leg value for weight math:
  - Chainlink price when **fresh AND sequencer up** (existing `_freshPrice`), else
  - **spot** from the v4 pool (`StateView.getSlot0` sqrtPriceX96 → `spotValueOf`,
    already added for redeem floors).
- Target-delta swaps execute with realized floors, buffer sourced the same way as
  redeem: `slipBufferBps` when priced off fresh Chainlink, `slipBufferStaleBps`
  (wider) when priced off spot.
- **Divergence guard**: keep it when Chainlink is fresh (reject/skip a leg whose
  spot is outside `maxDivergenceBps` of Chainlink). When Chainlink is stale,
  there's nothing to compare against, so it's floor-only.
- Rebalance NO LONGER reverts `MarketClosed`. `setTargetPortfolio` already
  succeeds when stale; the execute step must too.

Keep it a distinct code path from `AgentCurve.buy`/mint so mint's strict
`nav()`/`MarketClosed` behavior is untouched.

## Sequencer interaction
During a sequencer outage the chain can't execute anyway. On restart within the
grace window, the Chainlink-fresh branch is still gated by `_requireSequencerUp()`
(so it falls to the spot branch), and the spot branch runs with the wider stale
buffer. Floors remain the backstop; do not hard-block rebalance on grace.

## Off-chain (rebalancer agent) note — not contract scope
The agent should widen floors or skip a leg when pre-trade spot diverges sharply
from the last-known-fresh Chainlink mark, and should cap per-rebalance turnover.
The contract only enforces the floor it's handed; the agent sets sane floors.

## Tests to add/adjust
- rebalance **succeeds when all feeds are stale** (weekend sim), shifting weights
  via v4, bounded by the (stale, wider) floor — the core new behavior.
- rebalance uses Chainlink + divergence guard when fresh (existing
  `test_Rebalance_ShiftsWeightsViaV4` stays green).
- **manipulation bound**: a pre-rebalance spot pump on a stale feed cannot drain
  beyond the floor buffer (assert bounded loss / floor enforced), demonstrating
  authorized-only + floor is sufficient.
- **mint unchanged**: `test_Mint_RevertsMarketClosedWhenStale` still passes; mint
  still pauses on stale while rebalance does not.

## Implementation status (delivered)
IMPLEMENTED in `EquityTreasury.executeRebalanceStep` + tests (all green).
- Rebalance no longer calls `nav()`/`valueOf`. New staleness-tolerant sizing:
  `_rebalanceNav`, `_markValue`, `_markAmount` mark each leg at Chainlink when
  its feed is fresh (sequencer up) else at v4 spot (`spotValueOf` / a spot
  inverse). The step no longer reverts `MarketClosed`.
- Per-leg realized floor = max(caller floor, expected × (1 − buffer)); buffer is
  `slipBufferBps` when priced off fresh Chainlink else `slipBufferStaleBps`
  (`_sellFloor` / `_buyFloor`). Divergence guard skips a fresh-but-diverged leg
  (`RebalanceLegSkippedDiverged`); floor-only when stale.
- Distinct from `AgentCurve.buy`/mint — mint's `nav()`/`MarketClosed` gate is
  untouched. Redeem untouched.
- Tests: `test_Rebalance_SucceedsWhenAllFeedsStale` (weekend), `test_Rebalance_ShiftsWeightsViaV4`
  (fresh + divergence guard), `test_Rebalance_FloorBoundsManipulatedSpot`
  (stale-spot pump can't drain past the floor — the router's `amountOutMinimum`
  trips and the step reverts), `test_Rebalance247_DoesNotUngateMint` +
  `test_Mint_RevertsMarketClosedWhenStale` (mint still paused).
- Test-harness note: `MockUniversalRouterForked` now falls back to spot pricing
  when the Chainlink mark is stale, so weekend rebalance/redeem fill at execution
  (a real pool never consults Chainlink).
- `_markAmount`'s spot inverse assumes 18-dec equity tokens (the only class
  here). Generalize if a non-18-dec equity token is ever listed.
