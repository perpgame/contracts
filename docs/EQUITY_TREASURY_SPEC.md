# Equity Treasury — Design & Interface Spec

Real tokenized-equity baskets on Robinhood Chain, running **alongside** the
existing memecoin "stock" treasury. This is a new, self-contained asset class
(`equity`) — the existing `stock` contracts are **not** modified.

Status: **implemented**. Chainlink valuation + registry + factory + treasury +
the Uniswap v4 forked-router swap path (Permit2 funding + hand-encoded,
verified calldata) are all in place, compile, and are covered by tests
(`forge test` → 359 passed / 0 failed / 2 pre-existing skips). The forked-router
ABI (previously the P0 blocker) has been **verified on-chain** — see §4.2/§8.

---

## 1. Background & the homogeneous-basket decision

A "basket" is a token backed by an on-chain treasury holding a weighted set of
assets. Two asset classes exist today:

- `lt` — HyperEVM / Bounce (unrelated to this spec).
- `stock` — Robinhood Chain. Originally **tokenized equities** (Chainlink-fed,
  direct USDG Uniswap v3 pools), then **pivoted to memecoins** (Uniswap v3 TWAP
  pricing, USDG→WETH→token two-hop).

We now bring **real tokenized stocks** back as a **separate** class, `equity`,
without touching the memecoin path.

**Design decision (already made): baskets are homogeneous.** A basket is either
all-memecoin (v3 / TWAP, existing `StockTreasury`) **or** all-equity (v4 /
Chainlink, the new contracts). v3 and v4 are never mixed in one treasury. This
lets each treasury target a single DEX and a single pricing source — no runtime
branching between oracle regimes.

### Why Chainlink (not TWAP) for equities

Stock v4 pools have **no oracle hook** (`hooks == address(0)`), so an on-chain
Uniswap v4 TWAP is impossible — there is no observation buffer to `observe()`.
Every real equity, however, has a live Chainlink feed. So:

- **Pricing = Chainlink** (8-dec USD feeds, `us_equities_24/5`).
- **Execution = Uniswap v4** (direct USDG↔token pools, via the forked router).

This inverts the memecoin design (TWAP pricing + v3 execution) but reuses the
exact pre-pivot Chainlink math that was deleted at the pivot (see §7).

---

## 2. Architecture

```
                 EquityTreasuryFactory  (Ownable2Step)
                   │  deploys BeaconProxy → EquityTreasury impl
                   │  wires STABLE / ROUTER(v4 fork) / REGISTRY / feeRecipient
                   ▼
   AgentCurve ◄──► EquityTreasury  (Initializable, ReentrancyGuard, beacon impl)
   (REUSED,        │  holds USDG + equity legs at target bps
    unchanged)     │  deployUsdc / withdrawLtsTo / executeRebalanceStep
                   │
      ┌────────────┼─────────────────────────────┐
      ▼            ▼                               ▼
 EquityRegistry   EquityTreasuryValuation     V4SwapEncoder + IUniversalRouterForked
 (Chainlink       (DELEGATECALL lib: nav,     (hand-encoded v4 calldata —
  valueOf/amountOf, quoteWithdraw, held        FORK ABI UNVERIFIED)
  + v4 route)      values)
```

Mirrors the memecoin stack one-for-one:

| Memecoin (existing)         | Equity (new)                | Difference                          |
|-----------------------------|-----------------------------|-------------------------------------|
| `StockTreasury`             | `EquityTreasury`            | swap venue v3→v4; registry iface    |
| `StockTreasuryValuation`    | `EquityTreasuryValuation`   | registry iface only (same math)     |
| `StockTokenRegistry`        | `EquityRegistry`            | TWAP→Chainlink; v3 path→v4 PoolKey  |
| `StockTreasuryFactory`      | `EquityTreasuryFactory`     | `SWAP_ROUTER()`→`ROUTER()`          |
| `AgentCurve`                | **reused unchanged**        | same selectors                      |
| `ISwapRouter02`             | `IUniversalRouterForked`    | new venue                           |
| `OracleLibrary` (TWAP)      | `AggregatorV3Interface`     | Chainlink instead of ticks          |
| —                           | `V4PoolKey`, `V4SwapEncoder`, `IStateView` | new v4 plumbing      |

`AgentCurve` casts its treasury to `AgentTreasury` and only ever calls
`deployUsdc`, `withdrawLtsTo`, `quoteWithdrawUsdc`. `EquityTreasury` exposes
those three selectors identically, so the **same** `AgentCurve` bytecode is
spawned by `EquityTreasury.initialize` — no curve fork needed.

### On-chain addresses (Robinhood Chain)

| Role                      | Address |
|---------------------------|---------|
| PoolManager (v4)          | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| StateView (v4 lens)       | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` |
| V4Quoter                  | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| PositionManager (v4)      | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| **UniversalRouter (FORK)**| `0x8876789976dEcBfCbBbe364623C63652db8C0904` |
| USDG (stable, 6-dec)      | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| WETH                      | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

Equity pools are **direct USDG↔token** — no WETH hop (unlike memecoins). Fee
tier 3000 (tickSpacing 60) or 10000 (tickSpacing 200), `hooks = 0x0`.

---

## 3. Chainlink valuation module (`EquityRegistry`)

Revived pre-pivot math. All values are 6-dec stable (USDG) base units.

```
valueOf(token, amount)  = amount * price / 10^(tokenDec + feedDec - 6)
amountOf(token, stable) = stable * 10^(tokenDec + feedDec - 6) / price
```

For the standard equity case (18-dec token, 8-dec feed, 6-dec stable) the scale
divisor is `10^20`. Example: 1 AAPL (`1e18`) at `$200` (`200e8`) →
`1e18 * 200e8 / 1e20 = 200e6` = `$200`. ✔ (unit-tested in `EquityRegistry.t.sol`)

**Staleness / validity guards** (`_freshPrice`), applied to every mark:

1. `answer <= 0` → revert `InvalidPrice` (feed fault / negative price).
2. `block.timestamp > updatedAt + maxPriceAge` → revert `StalePrice`.

`maxPriceAge` defaults to **5 days** (covers a long weekend + a market holiday)
and is owner-tunable. Equity feeds are 24/5, so **weekend/after-hours staleness
is normal, not exceptional** — the treasury is built to tolerate it (see §6).

> Not (yet) implemented: a Chainlink **heartbeat** per-feed check or an L2
> **sequencer-uptime** feed. `maxPriceAge` is a single global age gate. See Open
> Questions.

Decimals (`tokenDecimals`, `feedDecimals`) are cached at `addToken` from
`IERC20Metadata.decimals()` and `AggregatorV3Interface.decimals()`.

---

## 4. v4 execution module

### 4.1 poolId resolution (`V4PoolKey`)

```
PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
poolId = keccak256(abi.encode(PoolKey))     // currencies sorted ascending, hooks = 0
```

`abi.encode` over plain `address` fields is byte-identical to canonical v4's
`Currency`/`IHooks` encoding (both address-width), so the computed id matches
the on-chain PoolManager. `EquityRegistry.addToken` validates the pool exists
by reading `StateView.getSlot0(poolId)` and requiring a non-zero `sqrtPriceX96`
(and optional `minPoolLiquidity` via `getLiquidity`).

### 4.2 Forked-router calldata (`V4SwapEncoder` + `IUniversalRouterForked`)

**VERIFIED** against the router's verified on-chain source
(robinhoodchain.blockscout.com, solc 0.8.26) and the Bags "Trade Tokens" guide.
Top-level entry: `execute(bytes commands, bytes[] inputs, uint256 deadline)`
(there is also `executeSigned(...)` — unused; we call `execute`).

For one exact-in single swap:

```
commands = [0x10]                            // V4_SWAP
inputs[0] = abi.encode(bytes actions, bytes[] params)
  actions = [0x06 SWAP_EXACT_IN_SINGLE, 0x0c SETTLE_ALL, 0x0f TAKE_ALL]
  params[0] = abi.encode(ExactInputSingleParams)
  params[1] = abi.encode(address inputCurrency,  uint256 amountIn)     // SETTLE_ALL
  params[2] = abi.encode(address outputCurrency, uint256 minAmountOut) // TAKE_ALL
```

**THE FORK DIVERGENCE (confirmed):** the fork's `ExactInputSingleParams` carries
an extra Robinhood-specific `minHopPriceX36` (`uint256`) field. Confirmed layout
— it is the **5th field, between `amountOutMinimum` and `hookData`** (NOT last):

```
struct ExactInputSingleParams {
  PoolKey poolKey; bool zeroForOne; uint128 amountIn; uint128 amountOutMinimum;
  uint256 minHopPriceX36;   // ← fork-added, before hookData
  bytes   hookData;
}
```

We pass `minHopPriceX36 = 0` to **disable** the router's per-hop price floor —
the treasury enforces its own realized-output floor (below). `MockUniversalRouterForked`
decodes this exact struct and asserts the `minHopPriceX36 == 0` slot, so the wire
format is regression-tested.

> Two earlier scaffold guesses were **wrong** and are now corrected — SETTLE_ALL
> is `0x0c` (not `0x0b`), and `minHopPriceX36` precedes `hookData` (not last).

### 4.3 Funding via Permit2 (confirmed)

The forked router pulls the input token through **Permit2**, not a direct router
`approve`. Permit2 = `0x000000000022D473030F116dDEE9F6B43aC78BA3` — **verified
two ways**: (a) canonical Permit2, has deployed code on Robinhood Chain
(`eth_getCode`), and (b) the exact `permit2` the router was constructed with,
decoded from the router's on-chain constructor args (`RouterParameters.permit2`,
word 0). Set as `EquityTreasury.PERMIT2` constant. Per swap: ensure a one-time
max token→Permit2 ERC-20 allowance, then `Permit2.approve(token, ROUTER,
uint160(amountIn), expiration)` sized to the exact input, then `ROUTER.execute`.

### 4.4 Slippage floors

The UniversalRouter's `execute()` returns nothing, so `EquityTreasury._v4ExactInput`
measures realized output as a **balance delta** (`balanceOf` after − before) and
reverts `SlippageExceeded` if it is below `minOut`. Does not trust the oracle
mark for execution.

---

## 5. Registry — how an equity token is registered

`EquityRegistry.addToken(token, feed, fee, tickSpacing)` (owner-only):

1. `token`/`feed` non-zero, not already registered, `fee != 0 && tickSpacing != 0`.
2. Build sorted `PoolKey(USDG, token, fee, tickSpacing, hooks=0)`, derive poolId.
3. Validate the pool is initialized (`StateView.getSlot0 → sqrtPrice != 0`) and,
   if `minPoolLiquidity > 0`, deep enough.
4. Cache `tokenDecimals`, `feedDecimals`, and `stableIsCurrency0`.

`setEnabled` (allowlist gate — disabling blocks new registration but keeps
valuing existing holdings so treasuries can exit), `setFeed`, `setRoute`,
`setMinTradeStable`, `setMaxPriceAge`, `setMinPoolLiquidity` are owner-tunable.

Read surface consumed by the treasury (`IEquityRegistry`): `tokenExists`,
`valueOf`, `amountOf`, `minTradeStable`, `maxPriceAge`, `poolKey`, `poolId`,
`stableIsCurrency0`.

---

## 6. Treasury behavior (`EquityTreasury`)

Storage layout, events, errors, weight math, prune/sweep, rebalancer two-step,
and the `AgentCurve` seed/spawn flow are **ported verbatim** from
`StockTreasury` (append-only `__gap`, `MAX_ASSETS = 20`, etc.). Only swap
plumbing and the registry/valuation types differ. Key equity-specific points:

- **`nav()`** sums held legs at Chainlink marks + idle USDG. If **any** held
  leg's feed is stale, `nav()` reverts (never marks at a dead feed), which
  freezes buy/sell/deploy — matching the memecoin freeze semantics.
- **`setTargetPortfolio` does not price**, so the rebalancer can rotate a
  stale/halted leg out even while `nav()` is frozen.
- **`withdrawLtsTo`** uses **tolerant per-leg valuation** (`try REGISTRY.valueOf`):
  a stale leg is settled **in-kind** (`returnTokens=true`) instead of bricking
  the exit. For equities this is the **common weekend case**, not an edge case,
  because feeds legitimately go stale every Friday close → Monday open.
- Audit-hardening carried over: pro-rata idle payout (not idle-first), the
  realized-stable floor enforced even on the `returnTokens=true` path (HIGH-1),
  and single-leg failure isolation on exit (HIGH-3).

Swap direction is derived from the registry's sorted key: `zeroForOne =
(tokenIn == poolKey.currency0)`. The withdraw deficit loop routes swaps through
`swapTokenForStableSelf` (an `address(this)`-only external shim) so a single bad
leg can be `try/catch`-isolated (a `try` cannot wrap an internal call).

---

## 7. Was pre-pivot Chainlink code reusable? — YES

The pre-pivot Chainlink `StockTokenRegistry` (git `620c571:src/StockTokenRegistry.sol`,
before commits `b8d07bd`/`269da55` rewrote it to Uniswap TWAP) contained exactly
the valuation we need: `valueOf`/`amountOf`, `_freshPrice` (staleness + non-positive
guards), `_scale` (decimal scaling), `maxPriceAge`, and the `MockAggregator` test
double. `EquityRegistry` **revives that math verbatim** and layers on the new v4
route storage (fee/tickSpacing/poolKey/poolId) in place of the old `poolFee`
field. The old `AggregatorV3Interface` and `MockAggregator` both still exist in
the tree and are reused as-is. This is the lowest-risk part of the build.

---

## 8. Open questions & risks (prioritized)

### P0 — Forked UniversalRouter ABI — ✅ RESOLVED
Verified against the router's verified on-chain source and the Bags guide, then
cross-checked against the router's decoded constructor args (see §4.2/§4.3):
- `minHopPriceX36` is `uint256`, positioned **before `hookData`** (5th field) —
  the earlier "appended last" guess was wrong. Passed `0` (floor disabled).
- Funding is **Permit2** (`0x0000...78BA3`), confirmed as the router's
  constructor `permit2` arg AND to have code on-chain — not a direct approve.
- Action bytes confirmed `[0x06, 0x0c, 0x0f]` — SETTLE_ALL is `0x0c`, not `0x0b`.
- `execute(bytes,bytes[],uint256)` returns nothing → realized output measured as
  a balance delta.
`V4SwapEncoder` + `EquityTreasury._v4ExactInput` are now real, tested against
`MockUniversalRouterForked` (which decodes and asserts the exact wire format).

### P1 — Weekend / after-hours feed staleness (behavioral, but by-design)
Equity feeds freeze 24/5. With `maxPriceAge = 5d`, `nav()` and all swaps revert
across every weekend/holiday. Confirm product intent:
- Should minting/redeeming be **disabled** when the feed is stale (current
  behavior: `nav()` reverts → curve buy/sell revert), or should redemption fall
  back to **in-kind only** (current `withdrawLtsTo` does this when `returnTokens`)?
- Is 5 days the right age for the longest expected market closure? (Some US
  holidays + weekend can approach it.)
- A stale feed during a **weekend swap attempt** by the rebalancer will revert
  the whole step — acceptable, but the off-chain rebalancer must schedule around
  market hours.

### P2 — Oracle robustness (audit surface)
- No **heartbeat** check per feed (only a global `maxPriceAge`); no L2
  **sequencer-uptime** feed. Consider adding both to `_freshPrice`.
- No **cross-check** between the Chainlink mark and the v4 pool price. Because
  execution is at pool price but sizing/NAV is at the oracle mark, a divergence
  (oracle right, pool stale/thin, or vice-versa) is borne by the realized-stable
  floor only. A max-divergence guard (oracle vs `V4Quoter` quote) would harden
  this — but reintroduces a manipulable spot input, so weigh carefully.
- `corporate-action` handling: `IStockToken.oraclePaused()` / `uiMultiplier()`
  exist but the equity treasury does **not** currently read `oraclePaused` — a
  frozen-for-corporate-action feed is caught only by the age gate. Consider
  gating on `oraclePaused()` explicitly.

### P3 — Pool / listing validation
- `addToken` only checks `sqrtPrice != 0` (initialized) + optional liquidity.
  It does **not** verify the pool's currencies actually match `(USDG, token)` at
  the declared fee — v4 has no `token0()`/`fee()` getters on a poolId the way v3
  pools expose them; the poolId itself encodes the pair, so a mismatched
  `fee`/`tickSpacing` simply yields an uninitialized id and reverts
  `PoolNotInitialized`. Confirm this is sufficient (it is, given the id binding),
  but document that a wrong tickSpacing for a real pool is indistinguishable from
  an unlisted pool.

### P4 — Test coverage blocked on P0
Swap-executing tests (deploy, rebalance, withdraw) can't run without a
`MockUniversalRouterForked`, which needs the confirmed ABI. Registry/valuation
tests are fully implemented and passing (`test/EquityRegistry.t.sol`).

---

## 9. File inventory

New (all under `contracts/`):

| File | Purpose |
|------|---------|
| `src/EquityRegistry.sol` | Chainlink valuation + v4 route + allowlist |
| `src/EquityTreasury.sol` | basket treasury (v4 execution, Chainlink marks) |
| `src/EquityTreasuryValuation.sol` | nav/quote DELEGATECALL lib + `AssetConfig` |
| `src/EquityTreasuryFactory.sol` | BeaconProxy deployer, wires v4 `ROUTER` |
| `src/interfaces/IEquityRegistry.sol` | treasury-facing registry surface |
| `src/interfaces/IUniversalRouterForked.sol` | forked router `execute` entry |
| `src/interfaces/IStateView.sol` | v4 StateView read surface (listing checks) |
| `src/libraries/V4PoolKey.sol` | PoolKey struct + sort + poolId |
| `src/libraries/V4SwapEncoder.sol` | **stub** — forked-router calldata |
| `test/mocks/MockStateView.sol` | settable v4 pool-init lens |
| `test/EquityRegistry.t.sol` | Chainlink valuation tests (**passing**) |
| `test/EquityTreasury.plan.t.sol` | test plan + blockers (skeleton) |
| `docs/EQUITY_TREASURY_SPEC.md` | this document |

Reused unchanged: `AgentCurve`, `AggregatorV3Interface`, `IStockToken`,
`MockAggregator`, `MockStockToken`, `MockUSDC`.

`forge build` passes; `forge test --match-contract EquityRegistryTest` → 7/7 green.
