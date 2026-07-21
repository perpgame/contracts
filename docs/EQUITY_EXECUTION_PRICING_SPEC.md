# Equity baskets: execution-priced mint/redeem

## Why
Equity v4 pools have **no oracle hook** → no on-chain TWAP; the only on-chain
Uniswap price is instantaneous **spot**, which is manipulable within a block.
Chainlink is manipulation-proof but goes **stale on weekends/holidays** (it
tracks the underlying regulated equity, which isn't trading). Neither alone is a
safe basis for issuance across a 24/7 chain.

Resolution: **do not price the core flows off a mark. Price them by realized
execution against the live pool.** A mark you can move is a mark you can steal
against; realized execution self-defeats manipulation (you sell into your own
price impact). Chainlink stops being the payout price and becomes a *guard* and
*display* input.

This mirrors what the treasury swap side already does (realized output +
`amountOutMinimum`), and depends on the P0 v4 swap path (`V4SwapEncoder` /
`EquityTreasury._v4ExactInput`) being finished first.

## The model in one line
- **Redeem** — always on, purely execution-priced (sell legs into the pool, pay
  realized USDG). Manipulation-proof, weekend-safe.
- **Mint** — needs a treasury valuation to set the share ratio, so anchor it on
  **Chainlink when fresh** and **pause mint when Chainlink is stale**. Users can
  still redeem, and the underlying tokens still trade permissionlessly on the
  pool; only *new share issuance* pauses on weekends.
- **Rebalance** — execution-priced, runs 24/7, floors sourced from Chainlink
  when fresh else a wider spot-derived buffer.
- **Chainlink's remaining jobs**: mint valuation, slippage-floor expected value,
  a divergence guard, and NAV display — **never** the redeem payout.

## Redeem (execution-priced, always available)
For `redeem(shares)`:
1. `frac = shares / totalSupply` (before burn).
2. For each leg `i`: `sellAmt_i = frac * legBalance_i`.
3. Sell each `sellAmt_i` into its USDG pool via `_v4ExactInput` (the P0 path),
   accumulating **realized** USDG from balance deltas.
4. `amountOutMinimum` per leg = `expected_i * (1 - slipBufferBps)`:
   - `expected_i` from **Chainlink when fresh**; when stale, from **pre-trade
     spot** (`StateView.getSlot0`) with a **wider** buffer (spot is only used to
     size the floor, not to compute the payout — a manipulated spot only makes
     the floor looser, and the realized proceeds are still whatever the pool
     gives, so it can't be gamed to *over*pay).
5. Pay the redeemer the **summed realized USDG**. No NAV mark enters the payout.
6. **In-kind fallback** (reuse StockTreasury's stale-leg exit): if a leg's swap
   would breach its floor / the pool can't absorb `sellAmt_i` (thin or stale),
   transfer that leg's `sellAmt_i` in-kind to the redeemer instead of forcing a
   bad swap. Redeem never blocks on one thin leg.
7. Burn `shares`. Enforce a global `minUsdcOut` (caller-supplied) over the total.

Why it's safe: inflating a leg's spot before redeeming just means the treasury
sells into the inflated price and the attacker (who moved it) bought high — the
manipulation cost ≈ the extra proceeds. No free lunch, at any pool depth.

## Mint (Chainlink-anchored, paused when stale)
For `mint(usdcIn)`:
1. **Require every leg's Chainlink feed fresh** (`!stale`), else `revert
   MarketClosed()` — issuance pauses on weekends/holidays by design.
2. `treasuryValue` = Σ `legBalance_i * chainlinkPrice_i` (fresh marks only).
3. Buy legs with `usdcIn` split by target weights via `_v4ExactInput` (realized).
4. `sharesOut = (usdcIn * totalSupply) / treasuryValue` (first mint / seed sets
   the initial ratio at deploy, unchanged from the existing seed path).
5. Guard each buy with a Chainlink-derived `amountOutMinimum` so a deflated pool
   can't hand the minter too many tokens.

Rationale: minting fundamentally requires trusting a valuation of the existing
treasury; using manipulable spot there would let an attacker deflate a pool,
mint cheap shares, restore, and redeem at fair value. Chainlink removes that;
pausing when Chainlink is absent is the safe default (redeem still works, and
pausing *issuance* — not trading — for ~2 days/week is acceptable). Do NOT
substitute spot for the mint valuation.

## Divergence guard (both flows, market hours)
Before any swap where Chainlink is fresh, require pre-trade spot within
`maxDivergenceBps` of Chainlink (`|spot - cl| / cl <= maxDivergenceBps`), else
revert/skip that leg. Catches a mid-market manipulated or broken pool even when
the oracle is live. Configurable per-asset in the registry; generous default
(e.g. 500–1000 bps) since equity pools legitimately drift from the underlying.

## Parameters (registry / treasury)
- `maxPriceAge` — comfortably past the 24h heartbeat so weekday overnights never
  trip (e.g. 90_000s). Staleness = weekends/holidays only.
- `slipBufferBps` (fresh) / `slipBufferStaleBps` (wider, spot-sourced).
- `maxDivergenceBps` — spot-vs-Chainlink band.
- All per-asset-overridable; sane global defaults.

## What changes vs the current scaffold
- `EquityTreasury.redeem`: replace any mark-based payout with the realized-USDG
  loop above + in-kind fallback. Keep `_v4ExactInput` from P0.
- `EquityTreasury.mint`: add the `stale ⇒ revert MarketClosed` gate and
  Chainlink-valued share math; keep realized buys.
- `EquityRegistry` / valuation lib: `nav()` stays Chainlink-based but is now
  **display/mint-only** (document it must NOT be used to price redeem).
- Add `maxDivergenceBps`, `slipBufferStaleBps` to config; add `MarketClosed`,
  `Diverged` errors + events for pause/fallback so the off-chain agent and UI
  can surface state.

## Edge cases / open questions
- **First mint / seed** at deploy sets the initial share↔value ratio — unchanged
  from the existing seed floor path; confirm it doesn't need a fresh feed at the
  exact deploy tx (it does — deploys should happen during market hours).
- **Rounding / dust** on the per-leg `frac` sells (reuse StockTreasury math).
- **MEV on redeem**: the per-leg `amountOutMinimum` + caller `minUsdcOut` are the
  sandwich protection; confirm buffers are wide enough for thin names.
- **All-legs-stale redeem** degrades to fully in-kind — acceptable (user gets the
  underlying tokens and can trade them on the live pool themselves).
- **Rebalance floors when stale**: agent should widen or skip; contract just
  enforces the floor it's given. Confirm the rebalancer two-step still applies.

## Tests to add
- redeem pays realized proceeds, unaffected by a pre-redeem spot pump (assert no
  over-payout) — the core manipulation-resistance test.
- redeem in-kind fallback when a leg breaches its floor.
- mint reverts `MarketClosed` when any leg feed is stale; succeeds when fresh.
- divergence guard reverts when spot is pushed outside the band mid-market.
- weekend simulation: mint paused, redeem (execution-priced) still succeeds.

## Implementation status (delivered)
IMPLEMENTED in `EquityTreasury` + `EquityRegistry` + tests (all green).
- **Redeem** (`withdrawLtsTo`) is now execution-priced: `sellAmt_i = frac ×
  legBalance_i`, summed REALIZED USDG (balance deltas) + pro-rata idle, per-leg
  floor from Chainlink (fresh) or spot (stale, wider buffer), in-kind fallback on
  a paused/diverged/thin/floor-breaching leg. No mark enters the payout.
- **Mint** stays Chainlink-anchored via `AgentCurve.buy → nav()`; `nav()` now
  reverts `MarketClosed(token)` when any held leg is stale, which pauses mint.
  Buys also gate on per-leg freshness + the divergence guard.
- **Rebalance is 24/7** (docs/EQUITY_REBALANCE_ANYTIME.md): a follow-up decoupled
  it from `nav()` — it uses staleness-tolerant sizing (Chainlink-fresh else spot)
  and no longer pauses with mint. Mint and redeem are unchanged by that change.
- **Divergence guard**: `maxDivergenceBps` (default 0 = disabled) on the registry;
  mint reverts `Diverged`, redeem routes the leg in-kind.
- **Params** live on `EquityRegistry`: `slipBufferBps` (3%), `slipBufferStaleBps`
  (10%), `maxDivergenceBps` (0). GLOBAL (not yet per-asset — a documented
  deviation to bound scope; add per-asset overrides later if needed).
- **Test-harness note**: `MockUniversalRouterForked` prices swaps at the
  Chainlink mark when fresh (value-conserving) and FALLS BACK TO SPOT when the
  Chainlink mark is stale — so weekend redeem/rebalance fill at execution
  (realized USDG), matching a real pool. The manipulation-resistance test still
  keeps the guard disabled and asserts no over-payout because execution ignores
  the pumped spot when Chainlink is fresh.
  Prior wording (kept for context): the "realized unaffected by spot pump" test asserts no over-payout precisely
  because execution ignores the pumped spot. A spot-priced mock (calibrated) is
  the follow-up for demonstrating weekend realized-USDG payout on a live pool.
