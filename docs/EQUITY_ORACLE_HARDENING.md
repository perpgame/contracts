# Equity oracle hardening (L2 sequencer + per-feed heartbeat)

Robinhood Chain is an **Arbitrum Orbit optimistic-rollup L2 with a centralized
sequencer**. Two hardening items on the Chainlink path, on top of the staleness
gate and divergence guard already in EQUITY_EXECUTION_PRICING_SPEC.md.

These gate the **Chainlink-dependent path only** (mint valuation + slippage-floor
expected-values). Execution-priced **redeem is unaffected** — once the chain is
live again it trades the pool directly. So the net effect of any trip below is
"issuance pauses, exits keep working," consistent with the pricing spec.

## 1. L2 Sequencer Uptime Feed guard
If the sequencer goes down, no txs land and Chainlink can't push updates; on
restart there's a window where the last price is stale but timestamps look
plausible and a backlog executes at a bad price. Guard it with Chainlink's L2
Sequencer Uptime Feed.

- Add immutable `sequencerUptimeFeed` (AggregatorV3Interface) to the treasury/
  valuation. **Fetch the real address from Chainlink's Robinhood feed list**
  (docs.chain.link/data-feeds/l2-sequencer-feeds and the Robinhood price-feeds
  page); if RH Chain doesn't publish one yet, make it OPTIONAL: `address(0)` =
  skip the check, with a loud comment + a deploy-time warning, so we don't ship
  a broken hardcode.
- New guard `_requireSequencerUp()`, called before any Chainlink read:
  ```
  (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
  // answer: 0 = up, 1 = down
  if (answer != 0) revert SequencerDown();
  if (startedAt == 0) revert SequencerDown();               // round not initialized
  if (block.timestamp - startedAt <= GRACE_PERIOD) revert SequencerGracePeriod();
  ```
- `GRACE_PERIOD` = **3600s** (industry standard; make it a configurable
  constant/immutable).
- Compose with existing logic: sequencer-down OR within-grace OR feed-stale ⇒
  Chainlink unusable ⇒ `mint` reverts (same as `MarketClosed`); redeem still
  runs execution-priced. Reuse/extend the existing pause path rather than adding
  a parallel one.
- Errors/events: `SequencerDown`, `SequencerGracePeriod` (or fold into the
  existing MarketClosed reason with an enum) so the off-chain agent/UI can tell
  "weekend" from "sequencer outage."

## 2. Per-feed heartbeat
Today a single global `maxPriceAge` covers all feeds. Move the heartbeat onto
each asset so a genuinely-dead feed is caught against its own cadence and future
feeds with different cadences work without a global retune.

- Add `uint32 heartbeat` to the per-asset config (`AssetConfig` in
  EquityTreasuryValuation / registered via EquityRegistry). Validate `> 0` on
  registration. Default 86_400 for the current equity/ETF feeds.
- Replace the global `maxPriceAge` staleness test with per-feed:
  `block.timestamp - updatedAt > heartbeat + staleSlackSeconds`
  where `staleSlackSeconds` is a small global cushion (e.g. 3_600) so a feed
  that's a little late isn't falsely rejected. Keep it per-asset-overridable.
- Everywhere that currently reads `maxPriceAge`, switch to the per-feed value.

## Tests to add
- sequencer **down** (`answer=1`) ⇒ mint reverts `SequencerDown`; redeem still
  succeeds (execution-priced).
- sequencer **just restarted** (`block.timestamp - startedAt < GRACE_PERIOD`) ⇒
  mint reverts `SequencerGracePeriod`; passes once grace elapses.
- `sequencerUptimeFeed == address(0)` ⇒ guard skipped (opt-out path) and prior
  behavior preserved.
- per-feed heartbeat: a feed stale against its own `heartbeat + slack` is
  rejected; a feed within it passes; two assets with different heartbeats each
  judged correctly.
- add a `MockSequencerFeed` (up/down + startedAt) for the above.

## Deploy note
`sequencerUptimeFeed` and each asset's `heartbeat` become deploy/registration
inputs — surface them in the factory/registry wiring and the off-chain config
(mirror into Onchain::Chain / the registry seed) so ops sets real values, not
placeholders.

## Implementation status (delivered)
IMPLEMENTED in `EquityRegistry` (+ `EquityTreasury` gate wiring) + tests (green).
- **Sequencer guard**: `SEQUENCER_UPTIME_FEED` immutable + `SEQUENCER_GRACE_PERIOD`
  = 3600. `_requireSequencerUp()` (revert `SequencerDown` / `SequencerGracePeriod`)
  runs before every reverting Chainlink read (`_freshPrice`); `isFeedFresh` folds
  in a non-reverting sequencer check. `requireSequencerUp()` is called on the
  treasury mint/NAV path so an outage surfaces DISTINCTLY (vs. weekend
  `MarketClosed`). Redeem never calls it.
  - ⚠️ **No confirmed Robinhood Chain uptime-feed address** was found at authoring
    (Chainlink's list is the source of truth but its page is JS-rendered; the RH
    docs defer to it). Shipped as **OPT-OUT** (`address(0)` = skip) with a loud
    comment — NOT a guessed hardcode. Ops must wire the real address when
    published.
- **Per-feed heartbeat**: `TokenInfo.heartbeat` (validated > 0, `DEFAULT_HEARTBEAT`
  = 86_400), global `staleSlackSeconds` = 3600. Staleness is now
  `now - updatedAt > heartbeat + staleSlackSeconds`; the old global `maxPriceAge`
  is removed. `setHeartbeat` allows per-asset retune.
  - **Home deviation**: the spec suggested `AssetConfig` (in
    EquityTreasuryValuation). Implemented on the registry's `TokenInfo` instead,
    because all feed/freshness logic lives in the registry and `AssetConfig` is
    the treasury's append-only upgrade-critical storage — putting feed metadata
    there would be both a layout risk and a duplication.
- **Wiring**: `EquityRegistry` constructor gains `sequencerUptimeFeed_`;
  `addToken` gains `heartbeat`. Deploy scripts / off-chain config must pass real
  values.
