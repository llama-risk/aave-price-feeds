# Equity price cap adapters

Price adapters for tokenized equities: tokens that represent a share in a listed company, issued on-chain against shares held by a custodian.

A tokenized equity has two moving parts, and both have to be read to price it. The share itself moves with the market, and the issuer publishes a **multiplier** that absorbs corporate actions — a 3-for-1 split takes it from `1.0` to `3.0`, a reinvested dividend nudges it up by the dividend's share of the price. One token is worth `share price × multiplier`.

These adapters compute that product and bound it in both directions.

## Contents

| Contract | Role |
| --- | --- |
| `EquityPriceCapAdapter` | Prices the token and clamps the result to a band. Issuer-agnostic. |
| `B20EquityMultiplier` | Reads the multiplier from a B20 token on Base. |
| `IEquityMultiplier` | The per-issuer read. One implementation per issuer. |
| `IEquityPriceCapAdapter` | Params, events, errors, and the view surface. |

## How the price is computed

```
raw    = underlying × multiplier / 10 ** MULTIPLIER_DECIMALS
band   = referencePrice ± maxDeviationBps
price  = min(max(raw, lowerBound), upperBound)
```

`latestAnswer()` returns `price` in the underlying feed's decimals. It returns `0` if either leg is unusable — a non-positive answer from the aggregator, or a zero multiplier — which is the convention the rest of this repository already follows for an unpriceable asset.

`getRawPrice()` exposes the unclamped product, and `isCapped()` reports whether the two currently differ. Both exist so an operator can see how far the market has moved from the band without recomputing the product off-chain.

## Why this is not a CAPO adapter

`PriceCapAdapterBase` caps an LST against a snapshot ratio growing at a fixed yearly rate. Three of its properties do not survive the move to equities.

**It caps in one direction.** An LST exchange rate only accrues, so a ratio above trend is the anomaly and a ratio below trend is a real loss that should be priced. An equity moves both ways, and for a lender the dangerous direction is down: an unbounded lower side lets one bad print mark an entire collateral class to near zero.

**It assumes smooth growth.** `maxYearlyRatioGrowthPercent` extrapolates a straight line from a snapshot, which suits something that drifts. An equity price does not drift predictably, and a multiplier does not drift at all — it is a step function that jumps 200% on a 3-for-1 split. No growth rate both admits that jump and still bounds anything.

**Its anchor is deliberately stale.** `_setCapParameters` requires the snapshot be older than `MINIMUM_SNAPSHOT_DELAY`, so a manipulated spot ratio cannot become the anchor. That protects an upper cap. Carried into a *lower* bound it inverts: after a genuine 20% gap the anchor sits above the market and the bound clamps a legitimate move, precisely when correct pricing matters most.

So the band here tracks a reference price that is seeded live at construction and advanced explicitly, and the deviation is symmetric.

What is kept from the CAPO family: the `ICLSynchronicityPriceAdapter` surface the Aave oracle calls, the `isRiskAdmin || isPoolAdmin` gate, immutables set in the constructor, and the two-input shape of a Chainlink feed times an on-chain factor. `PendlePriceCapAdapter` is the nearer relative — it also stands alone rather than inheriting the base, and also computes its own factor rather than reading a ratio provider.

## The band

`referencePrice` is the midpoint. It is seeded from the live price when the adapter is deployed, and moved afterwards by `updateReferencePrice()`.

Two properties of that function matter more than they look.

**It advances to the raw price, never the clamped one.** Advancing to the clamp would let the band walk toward a manipulated price one update at a time, each step looking individually reasonable while the destination is wrong. Taking the raw price means a reference update is a deliberate acceptance of where the market actually is.

**It is rate-limited by `MIN_REFERENCE_DELAY`.** Without a floor on the interval, a caller could advance the reference repeatedly within one block and walk the band anywhere regardless of the deviation bound.

Callable by `referenceUpdater`, the risk admin, or the pool admin. The updater is settable and may be `address(0)`, which leaves the two admins as the only callers.

### Sizing `maxDeviationBps`

The band is sized per asset, not once for the market. A fall that is ordinary for one name is extreme for another, and a single global number is wrong in both directions at once.

It also has to sit **wider than the collateral factor's own tolerance for that asset**. The collateral factor is calibrated against observed close-to-open falls; if the band is tighter than the fall the CF already absorbs, the adapter starts clamping during moves the market is expected to survive, and the adapter — not the CF — becomes the binding constraint. That converts a survivable weekend into a pricing incident.

`MAX_DEVIATION_BPS_LIMIT` caps the configurable value at 50%. It is a guard against a fat-fingered parameter, not a recommendation.

## What the band does and does not defend

The two inputs fail in different ways and need different defences.

| Input | Fails as | Defence |
| --- | --- | --- |
| Underlying price | a bad print, a thin book, a venue dropping out of the aggregation | the band |
| Multiplier | a compromised or mistaken issuer operator, a mis-sequenced update | a time gate, in the operational layer |

The band addresses the price leg. It deliberately puts **no magnitude bound on the multiplier**, because a legitimate 3-for-1 split is a 200% jump: any bound tight enough to catch a compromised operator would reject every real corporate action.

The defence that does work on the multiplier is a time gate — permit a change only around a scheduled corporate action — and that needs a corporate-action calendar. A calendar does not belong in a pricing contract: it is off-chain data, it changes on a schedule the contract cannot verify, and a pricing contract that reverts on a calendar mismatch takes the market down on a data problem. So the gate lives in the operational layer above, and this contract's contribution is to make the change *visible*: the price leaves the band, `isCapped()` turns true, and the published price stops following the multiplier while an operator decides what to do.

For the same reason the band is not a circuit breaker. It does not revert, pause, or latch. It clamps and stays live.

## Adding an issuer

Write one contract implementing `IEquityMultiplier` and deploy an `EquityPriceCapAdapter` pointing at it. The pricing contract never learns an issuer's ABI.

```solidity
interface IEquityMultiplier {
  function multiplier() external view returns (uint256);
  function multiplierDecimals() external view returns (uint8);
}
```

`multiplierDecimals()` is read once at construction and treated as immutable — an issuer that changed it afterwards would silently rescale every price.

Issuers differ in ways the interface does not hide, and should not:

- Some publish the multiplier directly with no timelock, no staging and no bound on the step size, so a single operator transaction moves it. Others schedule changes ahead with an activation timestamp, which gives the operational layer real lead time.
- At least one issuer distributes dividends off-chain at redemption rather than reinvesting them, so its multiplier moves on splits only. That is a different economic object, not a variation to normalise away, and it belongs in the listing decision rather than in this code.
- Rebasing tokens are out of scope. Where an issuer's token rebases, it needs a non-rebasing wrapper before it can be collateral at all, which is a question about the token rather than about pricing it.

## B20 on Base

`B20EquityMultiplier` is a pass-through: B20 exposes `multiplier()` on the token itself at 18 decimals, selector `0x1b3ed722`. The constructor reverts if the token reports a zero multiplier, so a misconfigured deployment fails immediately rather than at the first price read.

Two things worth knowing before wiring monitoring against it.

**The multiplier is not uniformly `1.0`.** Across the mag-7 tokens on Base, six read exactly `1e18` and GOOGLc reads `1000377118676784000` — consistent with a dividend having already flowed through. Any check asserting `multiplier() == 1e18` fires on the first read. Compare against a stored per-asset baseline instead.

**Announcements carry no lead time.** The token can emit an announcement bracketing a corporate action, but it is optional and atomic: emitted in the same transaction as the change itself. An event listener therefore finds out at the same moment as everyone else, and detection has to be polling plus the band.

## Known limitation

`multiplier × underlying` is a **redemption-rate** price: what the issuer would give on redemption, not what the token trades for. It assumes the token holds fair value against its redemption right, which breaks if redemption is suspended or the token depegs on secondary markets.

Aave carries the same assumption on every LST. It is part of why the band exists, and it belongs in the risk assessment for any listing that uses these adapters.

## Deployment

| Parameter | Description |
| --- | --- |
| `assetToUsdAggregator` | Chainlink feed for the underlying share, `SHARE / USD` |
| `equityMultiplier` | An `IEquityMultiplier` implementation for the issuer |
| `aclManager` | ACL manager of the pool; gates the setters |
| `referenceUpdater` | Address allowed to advance the reference, `address(0)` for admins only |
| `maxDeviationBps` | Band half-width in bps, sized per asset |
| `minReferenceDelay` | Minimum seconds between reference updates |
| `description` | e.g. `Capped AAPLc / USD` |

The adapter reads the live price at construction to seed the reference, so it must be deployed while the underlying feed is returning a usable answer.

## Tests

```
forge test --match-path "tests/EquityUnitTest.t.sol"
```

Covers construction and its reverts, clamping in both directions and at the band edges, the zero-price and zero-multiplier paths, a 3-for-1 split, the non-unit GOOGLc baseline, reference advancement including the raw-not-clamped rule and the delay, access control on every permissioned call, and a fuzz run asserting the published price never leaves the band.
