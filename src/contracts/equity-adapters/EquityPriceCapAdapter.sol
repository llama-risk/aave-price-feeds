// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IACLManager} from 'aave-address-book/AaveV3.sol';

import {IEquityPriceCapAdapter, ICLSynchronicityPriceAdapter, IChainlinkAggregator, IEquityMultiplier} from '../../interfaces/IEquityPriceCapAdapter.sol';

/**
 * @title EquityPriceCapAdapter
 * @author LlamaRisk
 * @notice Price adapter for tokenized equities, bounding the published price in both directions.
 *
 * The tokenized equity feed already reports the total return value of the token: the issuer's
 * multiplier is applied inside the feed, so its answer is the finished token price. This adapter
 * consumes that answer and clamps it to a band around a reference price:
 *
 *   band  = referencePrice +/- maxDeviationBps
 *   price = min(max(feedAnswer, lowerBound), upperBound)
 *
 * @dev The multiplier is read here but is deliberately NOT part of the price. Multiplying the feed
 *      answer by it again would apply the same corporate action twice: harmless while a multiplier
 *      sits at 1.0, and a factor-of-three error the day a 3-for-1 split lands. The multiplier is
 *      instead exposed as a cross-check, see `getImpliedUnderlyingPrice` and `EQUITY_MULTIPLIER`.
 *
 *      Why a band at all, when the feed is already a defended oracle. The off-hours methodology
 *      tracks a fast reference with a slow published series whose half-life stretches from 30
 *      minutes to 10 hours as the fast series diverges from the Friday anchor, and above 10%
 *      divergence the published range is unbounded by design. Venue-health HOLD freezes the feed
 *      on the last good snapshot while the market it prices keeps moving. Each of those is a
 *      deliberate choice by the feed, and each leaves the published price legitimately far from
 *      the tradable market. The band bounds what those choices let through; it is not a second
 *      opinion on the feed's own defences.
 *
 *      The band is two-sided, which is the substantive departure from the LST cap adapters here.
 *      An LST exchange rate only accrues, so capping from above is enough and a ratio below trend
 *      is a real loss that should be priced. An equity falls as well as rises, and for a lender
 *      the dangerous direction is down: an unbounded lower side lets one bad print mark a whole
 *      collateral class to near zero.
 *
 *      The band also tracks a reference seeded live rather than growing along a fixed rate from a
 *      governance snapshot. The LST adapters require their snapshot to be stale by construction so
 *      a manipulated spot ratio cannot become the anchor, which protects an upper cap. On a lower
 *      bound the same staleness inverts: after a genuine gap the anchor sits above the market and
 *      clamps a legitimate move, precisely when correct pricing matters most.
 *
 *      The band is not a circuit breaker. It does not revert, pause or latch. A pricing contract
 *      that reverts takes the market down on a data problem, which is worse than the mispricing it
 *      avoids. It clamps and stays live, and the decision to freeze is taken by an operator.
 */
contract EquityPriceCapAdapter is IEquityPriceCapAdapter {
  /// @inheritdoc IEquityPriceCapAdapter
  uint16 public constant MAX_DEVIATION_BPS_LIMIT = 5_000;

  /// @inheritdoc IEquityPriceCapAdapter
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @dev Guards the implied-underlying division against an implausible scale; every issuer seen
  ///      so far reports 8 or 18.
  uint8 internal constant MAX_MULTIPLIER_DECIMALS = 36;

  /// @inheritdoc IEquityPriceCapAdapter
  IChainlinkAggregator public immutable ASSET_TO_USD_AGGREGATOR;

  /// @inheritdoc IEquityPriceCapAdapter
  IEquityMultiplier public immutable EQUITY_MULTIPLIER;

  /// @inheritdoc IEquityPriceCapAdapter
  IACLManager public immutable ACL_MANAGER;

  /// @inheritdoc IEquityPriceCapAdapter
  uint8 public immutable MULTIPLIER_DECIMALS;

  /// @inheritdoc IEquityPriceCapAdapter
  uint32 public immutable MIN_REFERENCE_DELAY;

  /// @dev Scale of the published price, inherited from the feed
  uint8 internal immutable _DECIMALS;

  /// @dev 10 ** MULTIPLIER_DECIMALS, cached for the cross-check
  uint256 internal immutable _MULTIPLIER_SCALE;

  /// @inheritdoc ICLSynchronicityPriceAdapter
  string public description;

  /// @inheritdoc IEquityPriceCapAdapter
  address public referenceUpdater;

  /// @inheritdoc IEquityPriceCapAdapter
  uint16 public maxDeviationBps;

  /// @inheritdoc IEquityPriceCapAdapter
  uint256 public referencePrice;

  /// @inheritdoc IEquityPriceCapAdapter
  uint48 public referenceTimestamp;

  /**
   * @param params parameters to create the adapter
   */
  constructor(EquityPriceCapAdapterParams memory params) {
    if (
      params.assetToUsdAggregator == address(0) ||
      params.equityMultiplier == address(0) ||
      params.aclManager == address(0)
    ) {
      revert ZeroAddress();
    }

    ASSET_TO_USD_AGGREGATOR = IChainlinkAggregator(params.assetToUsdAggregator);
    EQUITY_MULTIPLIER = IEquityMultiplier(params.equityMultiplier);
    ACL_MANAGER = IACLManager(params.aclManager);

    _DECIMALS = ASSET_TO_USD_AGGREGATOR.decimals();

    uint8 multiplierDecimals = EQUITY_MULTIPLIER.multiplierDecimals();
    if (multiplierDecimals == 0 || multiplierDecimals > MAX_MULTIPLIER_DECIMALS) {
      revert UnsupportedMultiplierDecimals();
    }
    MULTIPLIER_DECIMALS = multiplierDecimals;
    _MULTIPLIER_SCALE = 10 ** multiplierDecimals;

    MIN_REFERENCE_DELAY = params.minReferenceDelay;
    description = params.description;

    referenceUpdater = params.referenceUpdater;
    emit ReferenceUpdaterUpdated(address(0), params.referenceUpdater);

    _setMaxDeviationBps(params.maxDeviationBps);

    // Seed the reference from the live feed. There is no governance snapshot to anchor to, and a
    // stale anchor is actively harmful on the lower side: after a real gap it would sit above the
    // market and clamp a legitimate move.
    uint256 seed = getFeedPrice();
    if (seed == 0) {
      revert InvalidReferencePrice();
    }
    referencePrice = seed;
    referenceTimestamp = uint48(block.timestamp);
    emit ReferencePriceUpdated(0, seed, block.timestamp);
  }

  /// @inheritdoc ICLSynchronicityPriceAdapter
  function latestAnswer() external view returns (int256) {
    uint256 feedPrice = getFeedPrice();
    if (feedPrice == 0) {
      return 0;
    }

    (uint256 lowerBound, uint256 upperBound) = getBounds();

    uint256 price = feedPrice;
    if (price < lowerBound) {
      price = lowerBound;
    } else if (price > upperBound) {
      price = upperBound;
    }

    // Safe: `price` is bounded above by `upperBound`, itself derived from a reference that only
    // ever held a value read from the aggregator as a positive int256.
    // forge-lint: disable-next-line(unsafe-typecast)
    return int256(price);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function getFeedPrice() public view returns (uint256) {
    int256 feedPrice = ASSET_TO_USD_AGGREGATOR.latestAnswer();
    if (feedPrice <= 0) {
      return 0;
    }

    // Safe: `feedPrice > 0` is checked above.
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint256(feedPrice);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function getImpliedUnderlyingPrice() external view returns (uint256) {
    uint256 feedPrice = getFeedPrice();
    if (feedPrice == 0) {
      return 0;
    }

    uint256 multiplier = EQUITY_MULTIPLIER.multiplier();
    if (multiplier == 0) {
      return 0;
    }

    return (feedPrice * _MULTIPLIER_SCALE) / multiplier;
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function getBounds() public view returns (uint256 lowerBound, uint256 upperBound) {
    uint256 currentReference = referencePrice;
    uint256 delta = (currentReference * maxDeviationBps) / BPS_DENOMINATOR;

    return (currentReference - delta, currentReference + delta);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function isCapped() external view returns (bool) {
    uint256 feedPrice = getFeedPrice();
    if (feedPrice == 0) {
      return false;
    }

    (uint256 lowerBound, uint256 upperBound) = getBounds();

    return feedPrice < lowerBound || feedPrice > upperBound;
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function updateReferencePrice() external {
    if (
      msg.sender != referenceUpdater &&
      !ACL_MANAGER.isRiskAdmin(msg.sender) &&
      !ACL_MANAGER.isPoolAdmin(msg.sender)
    ) {
      revert CallerIsNotReferenceUpdater();
    }

    if (block.timestamp < referenceTimestamp + MIN_REFERENCE_DELAY) {
      revert ReferenceUpdatedTooRecently();
    }

    // The reference advances to the feed price, never to the clamped one. Advancing to the clamp
    // would let the band walk toward a manipulated price one update at a time, each step looking
    // individually valid.
    uint256 newReferencePrice = getFeedPrice();
    if (newReferencePrice == 0) {
      revert InvalidReferencePrice();
    }

    uint256 oldReferencePrice = referencePrice;
    referencePrice = newReferencePrice;
    referenceTimestamp = uint48(block.timestamp);

    emit ReferencePriceUpdated(oldReferencePrice, newReferencePrice, block.timestamp);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function setMaxDeviationBps(uint16 newMaxDeviationBps) external {
    _onlyRiskOrPoolAdmin();

    _setMaxDeviationBps(newMaxDeviationBps);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function setReferenceUpdater(address newReferenceUpdater) external {
    _onlyRiskOrPoolAdmin();

    address oldReferenceUpdater = referenceUpdater;
    referenceUpdater = newReferenceUpdater;

    emit ReferenceUpdaterUpdated(oldReferenceUpdater, newReferenceUpdater);
  }

  /// @inheritdoc ICLSynchronicityPriceAdapter
  function decimals() external view returns (uint8) {
    return _DECIMALS;
  }

  /**
   * @notice Reverts unless the caller is the risk admin or the pool admin
   */
  function _onlyRiskOrPoolAdmin() internal view {
    if (!ACL_MANAGER.isRiskAdmin(msg.sender) && !ACL_MANAGER.isPoolAdmin(msg.sender)) {
      revert CallerIsNotRiskOrPoolAdmin();
    }
  }

  /**
   * @notice Sets the deviation bound
   * @param newMaxDeviationBps New bound in bps
   */
  function _setMaxDeviationBps(uint16 newMaxDeviationBps) internal {
    if (newMaxDeviationBps == 0 || newMaxDeviationBps > MAX_DEVIATION_BPS_LIMIT) {
      revert InvalidMaxDeviationBps();
    }

    uint16 oldMaxDeviationBps = maxDeviationBps;
    maxDeviationBps = newMaxDeviationBps;

    emit MaxDeviationBpsUpdated(oldMaxDeviationBps, newMaxDeviationBps);
  }
}
