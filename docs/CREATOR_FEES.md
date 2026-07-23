# Creator fee split

Splits the existing protocol commission between the platform and the token's
creator. **The trader's total fee is unchanged** — the same `feeBps` is charged;
it is just divided at the point of collection.

- Platform share: **25%** of the fee
- Creator share: **75%** of the fee (`DEFAULT_CREATOR_FEE_SHARE_BPS = 7500`)

## Where the split lives

`creatorFeeShareBps` is bps **of the fee**, not of the trade. It is configured on
each factory and **captured by each treasury at `initialize`**, so a token's
split is fixed for its lifetime and independent of later factory retunes.

| Contract | Change |
| --- | --- |
| `TreasuryFactory` / `StockTreasuryFactory` / `EquityTreasuryFactory` | `creatorFeeShareBps` (default 7500), `setCreatorFeeShareBps` (owner-only, capped at `MAX_CREATOR_FEE_SHARE_BPS = 10000`), `CreatorFeeShareBpsSet` event |
| `AgentTreasury` / `StockTreasury` / `EquityTreasury` | new `creatorFeeShareBps` storage captured at `initialize`; `_splitFee(token, fee)` helper applied at every sell-fee site (stable **and** in-kind token fees) |
| `AgentCurve` | `buy()` splits the buy fee via `_payFee` (reads `TREASURY.creatorFeeShareBps()` + `TREASURY.CREATOR()`) — one change covers all three families, which all spawn `AgentCurve` |

Split math (applied per fee event):

```
creatorCut  = fee * creatorFeeShareBps / 10000   // to CREATOR
platformCut = fee - creatorCut                    // to feeRecipient()
```

## Backward compatibility

`creatorFeeShareBps == 0` means the whole fee goes to the platform, exactly as
before. Two independent guarantees make this **new-deployments-only**:

1. **Treasuries** (beacon-upgradeable): a treasury deployed before this change
   never ran `initialize` with the new slot set, so it reads `0` across the
   beacon upgrade — behavior is byte-for-byte unchanged.
2. **`AgentCurve`** (immutable, one per token): existing tokens keep their
   original curve bytecode; the buy-fee split only ships in the curve spawned by
   a freshly deployed treasury.

## Rollout (new deployments only)

The factories are **not upgradeable** (they gained a storage variable), so they
must be redeployed:

1. Deploy new treasury implementations (they embed the new `AgentCurve`) and
   point the beacon at them. Existing treasuries are unaffected (`share == 0`).
2. Deploy the three factories fresh; each defaults `creatorFeeShareBps` to 7500.
3. Point the backend deploy config at the new factory addresses
   (`TREASURY_FACTORY_ADDRESS` / `STOCK_TREASURY_FACTORY_ADDRESS` /
   the equity factory address). Tokens launched afterwards carry the 25/75 split.

To retune later, the owner calls `setCreatorFeeShareBps(next)` on a factory; it
takes effect for tokens deployed **after** that call.

## Tests

- `AgentCurve.t.sol` — buy/sell split, in-kind LT split, capture-at-init, and the
  zero-share legacy path.
- `TreasuryFactory.t.sol` — setter owner-gating + cap, and that a deployed
  treasury locks in the factory's share and ignores later retunes.
- `StockTreasury.t.sol` / `EquityTreasury.t.sol` — sell-fee split on the stable
  and in-kind paths.
