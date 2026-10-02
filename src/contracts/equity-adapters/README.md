# Equity price cap adapters

Price adapters for tokenized equities: tokens that represent a share in a listed company, issued on-chain against shares held by a custodian.

A tokenized equity has two moving parts. The share itself moves with the market, and the issuer publishes a **multiplier** that absorbs corporate actions — a 3-for-1 split takes it from `1.0` to `3.0`, a reinvested dividend nudges it up by the dividend's share of the price. One token is worth `share price × multiplier`.

**That multiplication happens inside the feed.** The tokenized equity feeds report the total return value of the token: they read the issuer's multiplier from the token contract and publish the finished token price. An integrator consumes one number.

These adapters take that number, bound it in both directions, and read the multiplier separately as a cross-check.

## Contents

| Contract | Role |
| --- | --- |
| `EquityPriceCapAdapter` | Clamps the feed's answer to a band. Issuer-agnostic. |
| `B20EquityMultiplier` | Reads the multiplier from a B20 token on Base, for the cross-check. |
| `IEquityMultiplier` | The per-issuer read. One implementation per issuer. |
| `IEquityPriceCapAdapter` | Params, events, errors, and the view surface. |

## How the price is computed

```
band   = referencePrice ± maxDeviationBps
price  = min(max(feedAnswer, lowerBound), upperBound)
```

That is the whole pricing path. The multiplier does not appear in it.

`latestAnswer()` returns `price` in the feed's decimals, and `0` if the feed reports a non-positive answer — the convention the rest of this repository uses for an unpriceable asset. `getFeedPrice()` exposes the unclamped answer and `isCapped()` reports whether the two currently differ, so an operator can see how far the market has moved from the band without recomputing anything.

### Why the multiplier is not multiplied in

The feed answer already contains it. Multiplying again would apply the same corporate action twice:

```
correct:    feed answer                     = equity × multiplier
wrong:      feed answer × multiplier        = equity × multiplier²
```

While a multiplier sits at `1.0` the error is invisible, which is what makes the mistake dangerous — it surfaces for the first time on the day a split lands, as a factor-of-three mispricing. There is a test asserting the published price does not move when the multiplier changes, and a fuzz test asserting no multiplier value can move it.

## The cross-check

`getImpliedUnderlyingPrice()` divides the feed answer by the live multiplier, recovering the bare share price:

```
implied share price = feedAnswer × 10 ** MULTIPLIER_DECIMALS / multiplier
```

This is never part of the published price. It exists because the feed picks up the multiplier on its own publication schedule, so there is a window between an issuer writing a new multiplier and the feed reflecting it. Inside that window the feed is pricing the token against the old multiplier, and the implied share price steps discontinuously by the corporate action's ratio.

That discontinuity is the only on-chain signal of the desync, and it is invisible from either input alone: the feed looks like a normal price, and the multiplier looks like a normal corporate action. Only the ratio between them shows the two sides disagreeing.

The window differs sharply by event, because feeds republish on a deviation threshold or a heartbeat, whichever comes first:

- A **reinvested dividend** moves the multiplier by a fraction of a percent. That is below a typical deviation threshold, so the feed may not republish until the heartbeat expires — potentially many hours during which the token is worth slightly more than the feed says.
- A **split** moves it by 100% or more, blowing through any deviation threshold immediately. The window is short, but the error inside it is enormous.

A single monitoring threshold will not catch both. The small, slow one is the easier to miss.

## Why a band at all

The feed is already a defended oracle, so a second bound has to earn its place. It does, because several of the feed's own defences are deliberate choices that leave the published price legitimately far from the tradable market:

- Off-hours, a slow published series chases a fast reference with a half-life that **stretches from 30 minutes to 10 hours** as the fast series diverges from the Friday anchor. A real weekend move enters the published price slowly by design.
- Above 10% anchor divergence the published range is **unbounded by design**.
- A venue-health HOLD freezes the feed on its last good snapshot while the market it prices keeps moving.

The band bounds what those choices let through. It is not a second opinion on the feed's methodology — it is a floor and ceiling on how far the number Aave consumes can travel before a human looks at it.

## Why this is not a CAPO adapter

`PriceCapAdapterBase` caps an LST against a snapshot ratio growing at a fixed yearly rate. Two of its properties do not survive the move to equities.

**It caps in one direction.** An LST exchange rate only accrues, so a ratio above trend is the anomaly and a ratio below trend is a real loss that should be priced. An equity moves both ways, and for a lender the dangerous direction is down: an unbounded lower side lets one bad print mark an entire collateral class to near zero.

**Its anchor is deliberately stale.** `_setCapParameters` requires the snapshot be older than `MINIMUM_SNAPSHOT_DELAY`, so a manipulated spot ratio cannot become the anchor. That protects an upper cap. Carried into a *lower* bound it inverts: after a genuine 20% gap the anchor sits above the market and the bound clamps a legitimate move, precisely when correct pricing matters most.

So the band here is symmetric, and tracks a reference seeded live at construction rather than a governance snapshot extrapolated along a growth rate.

What is kept from the CAPO family: the `ICLSynchronicityPriceAdapter` surface the Aave oracle calls, the `isRiskAdmin || isPoolAdmin` gate, and immutables set in the constructor. `PendlePriceCapAdapter` is the nearer relative — it also stands alone rather than inheriting the base.

## The band

`referencePrice` is the midpoint. It is seeded from the live feed when the adapter is deployed, and moved afterwards by `updateReferencePrice()`.

Two properties of that function matter more than they look.

**It advances to the feed price, never the clamped one.** Advancing to the clamp would let the band walk toward a manipulated price one update at a time, each step looking individually reasonable while the destination is wrong. Taking the feed price means a reference update is a deliberate acceptance of where the market actually is.

**It is rate-limited by `MIN_REFERENCE_DELAY`.** Without a floor on the interval, a caller could advance the reference repeatedly within one block and walk the band anywhere regardless of the deviation bound.

Callable by `referenceUpdater`, the risk admin, or the pool admin. The updater is settable and may be `address(0)`, which leaves the two admins as the only callers.

### Sizing `maxDeviationBps`

The band is sized per asset, not once for the market. A fall that is ordinary for one name is extreme for another, and a single global number is wrong in both directions at once.

It also has to sit **wider than the collateral factor's own tolerance for that asset**. The collateral factor is calibrated against observed close-to-open falls; if the band is tighter than the fall the CF already absorbs, the adapter starts clamping during moves the market is expected to survive, and the adapter — not the CF — becomes the binding constraint. That converts a survivable weekend into a pricing incident.

`MAX_DEVIATION_BPS_LIMIT` caps the configurable value at 50%. It is a guard against a fat-fingered parameter, not a recommendation.

## What the band does not defend

The band bounds the price. It puts **no magnitude bound on the multiplier**, and could not usefully do so: a legitimate 3-for-1 split is a 200% jump, so any bound tight enough to catch a compromised issuer operator would reject every real corporate action.

The defence that works on the multiplier is a time gate — permit a change only around a scheduled corporate action — and that needs a corporate-action calendar. A calendar does not belong in a pricing contract: it is off-chain data the contract cannot verify, and a pricing contract that reverts on a calendar mismatch takes the market down on a data problem. So the gate lives in the operational layer, and this contract's contribution is visibility: `getImpliedUnderlyingPrice()` moves, and if the feed follows the multiplier far enough, `isCapped()` turns true.

For the same reason the band is not a circuit breaker. It does not revert, pause, or latch. It clamps and stays live.

## Adding an issuer

Write one contract implementing `IEquityMultiplier` and deploy an `EquityPriceCapAdapter` pointing at it. The pricing contract never learns an issuer's ABI.

```solidity
interface IEquityMultiplier {
  function multiplier() external view returns (uint256);
  function multiplierDecimals() external view returns (uint8);
}
```

`multiplierDecimals()` is read once at construction and treated as immutable — an issuer that changed it afterwards would silently rescale the cross-check.

Issuers differ in ways the interface does not hide, and should not:

- Some publish the multiplier directly with no timelock, no staging and no bound on the step size, so a single operator transaction moves it. Others schedule changes ahead with an activation timestamp, which gives the operational layer real lead time.
- At least one issuer distributes dividends off-chain at redemption rather than reinvesting them, so its multiplier moves on splits only. That is a different economic object, not a variation to normalise away, and it belongs in the listing decision rather than in this code.

These adapters price a token whose balance does not change on its own. A token that rebases is a different integration problem, upstream of pricing, and nothing here addresses it.

## B20 on Base

`B20EquityMultiplier` is a pass-through: B20 exposes `multiplier()` on the token itself at 18 decimals, selector `0x1b3ed722`. The constructor reverts if the token reports a zero multiplier, so a misconfigured deployment fails immediately rather than silently disabling the cross-check.

**The multiplier is not uniformly `1.0`.** Across the mag-7 tokens on Base, six read exactly `1e18` and GOOGLc reads `1000377118676784000` — a reinvested dividend that has already flowed through and is already inside the feed's answer. Any check asserting `multiplier() == 1e18` fires on the first read. Compare against a stored per-asset baseline instead.

**Announcements carry no lead time.** The token can emit an announcement bracketing a corporate action, but it is optional and atomic: emitted in the same transaction as the change itself. An event listener therefore finds out at the same moment as everyone else, and detection has to be polling plus the cross-check.

## Known limitation

The feed's price is a **redemption-rate** price: what the issuer would give on redemption, not what the token trades for. It assumes the token holds fair value against its redemption right, which breaks if redemption is suspended or the token depegs on secondary markets.

Aave carries the same assumption on every LST. It is part of why the band exists, and it belongs in the risk assessment for any listing that uses these adapters.

## Deployment

| Parameter | Description |
| --- | --- |
| `assetToUsdAggregator` | Tokenized equity feed for the token, already total-return |
| `equityMultiplier` | An `IEquityMultiplier` implementation for the issuer |
| `aclManager` | ACL manager of the pool; gates the setters |
| `referenceUpdater` | Address allowed to advance the reference, `address(0)` for admins only |
| `maxDeviationBps` | Band half-width in bps, sized per asset |
| `minReferenceDelay` | Minimum seconds between reference updates |
| `description` | e.g. `Capped AAPLc / USD` |

The adapter reads the live feed at construction to seed the reference, so it must be deployed while the feed is returning a usable answer.

## Tests

```
forge test --match-path "tests/EquityUnitTest.t.sol"
```

31 tests. Construction and its reverts; clamping in both directions and at the band edges; the zero-price path; that a multiplier change does not move the published price, including under fuzz; the cross-check at unit and non-unit multipliers, and the split desync it is there to reveal; reference advancement including the feed-not-clamped rule and the delay; access control on every permissioned call; and a fuzz run asserting the published price never leaves the band.
