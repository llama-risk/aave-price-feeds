// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IACLManager} from 'aave-address-book/AaveV3.sol';

import {IEquityPriceCapAdapter, ICLSynchronicityPriceAdapter, IChainlinkAggregator, IEquityMultiplier} from '../../interfaces/IEquityPriceCapAdapter.sol';

/**
 * @title EquityPriceCapAdapter
 * @author LlamaRisk
 * @notice Price adapter for tokenized equities, bounding the price in both directions.
 *
 * The published price is the price of the underlying share multiplied by the issuer's multiplier,
 * clamped to a band around a reference price:
 *
 *   raw   = underlying * multiplier / 10 ** MULTIPLIER_DECIMALS
 *   band  = referencePrice +/- maxDeviationBps
 *   price = min(max(raw, lowerBound), upperBound)
 *
 * @dev Three things separate this from the LST cap adapters in this repository.
 *
 *      The band is two-sided. An LST exchange rate only accrues, so capping it from above is
 *      enough: a ratio below trend is a real loss and should be priced. An equity moves both
 *      ways, and for a lender the dangerous direction is down, so an unbounded lower side would
 *      let a single bad print mark the whole collateral class to near zero.
 *
 *      The band tracks a reference price rather than growing along a fixed rate from a snapshot.
 *      The LST adapters extrapolate a smooth yearly growth, which suits a quantity that drifts.
 *      An equity price does not drift predictably, and a multiplier does not drift at all: it is
 *      a step function that jumps 200% on a 3-for-1 split. Nothing derived from a growth rate can
 *      both admit that jump and still bound anything useful.
 *
 *      Consequently the multiplier carries no magnitude bound here. Its failure mode is a
 *      compromised or mistaken issuer operator, and the defence is a time gate that only permits
 *      a change around a scheduled corporate action. That gate needs a corporate-action calendar,
 *      which does not belong in a pricing contract, so it sits in the operational layer above.
 *      What this contract does is make such a change visible: the price moves outside the band,
 *      `isCapped()` turns true, and the published price stops following the multiplier.
 *
 *      The band is deliberately not a circuit breaker. It does not revert, does not pause and
 *      does not latch. A pricing contract that reverts takes the market down on a data problem,
 *      which is worse than the mispricing it avoids. It clamps and stays live, and the decision
 *      to freeze is taken by an operator reading `isCapped()`.
 */
contract EquityPriceCapAdapter is IEquityPriceCapAdapter {
  /// @inheritdoc IEquityPriceCapAdapter
  uint16 public constant MAX_DEVIATION_BPS_LIMIT = 5_000;

  /// @inheritdoc IEquityPriceCapAdapter
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @dev Above this scale the product of price and multiplier risks overflowing uint256 for
  ///      plausible prices; every issuer seen so far reports 8 or 18.
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

  /// @dev Scale of the published price, inherited from the underlying feed
  uint8 internal immutable _DECIMALS;

  /// @dev 10 ** MULTIPLIER_DECIMALS, cached to keep `latestAnswer` cheap
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

    // Seed the reference from the live price. Unlike the LST adapters there is no governance
    // snapshot to anchor to: a stale anchor is actively harmful on the lower side, since after a
    // real gap it would sit above the market and clamp a legitimate move.
    uint256 seed = getRawPrice();
    if (seed == 0) {
      revert InvalidReferencePrice();
    }
    referencePrice = seed;
    referenceTimestamp = uint48(block.timestamp);
    emit ReferencePriceUpdated(0, seed, block.timestamp);
  }

  /// @inheritdoc ICLSynchronicityPriceAdapter
  function latestAnswer() external view returns (int256) {
    uint256 rawPrice = getRawPrice();
    if (rawPrice == 0) {
      return 0;
    }

    (uint256 lowerBound, uint256 upperBound) = getBounds();

    uint256 price = rawPrice;
    if (price < lowerBound) {
      price = lowerBound;
    } else if (price > upperBound) {
      price = upperBound;
    }

    // Safe: `price` is bounded above by `upperBound`, itself derived from a uint256 reference
    // scaled by at most 1.5x, and the reference only ever holds a value that fit in int256 when
    // it was read from the aggregator.
    // forge-lint: disable-next-line(unsafe-typecast)
    return int256(price);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function getRawPrice() public view returns (uint256) {
    int256 underlyingPrice = ASSET_TO_USD_AGGREGATOR.latestAnswer();
    if (underlyingPrice <= 0) {
      return 0;
    }

    uint256 multiplier = EQUITY_MULTIPLIER.multiplier();
    if (multiplier == 0) {
      return 0;
    }

    // Safe: `underlyingPrice > 0` is checked above.
    // forge-lint: disable-next-line(unsafe-typecast)
    return (uint256(underlyingPrice) * multiplier) / _MULTIPLIER_SCALE;
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function getBounds() public view returns (uint256 lowerBound, uint256 upperBound) {
    uint256 currentReference = referencePrice;
    uint256 delta = (currentReference * maxDeviationBps) / BPS_DENOMINATOR;

    return (currentReference - delta, currentReference + delta);
  }

  /// @inheritdoc IEquityPriceCapAdapter
  function isCapped() external view returns (bool) {
    uint256 rawPrice = getRawPrice();
    if (rawPrice == 0) {
      return false;
    }

    (uint256 lowerBound, uint256 upperBound) = getBounds();

    return rawPrice < lowerBound || rawPrice > upperBound;
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

    // The reference advances to the raw price, never to the clamped one. Advancing to the clamp
    // would let the band walk toward a manipulated price one update at a time, each step looking
    // individually valid.
    uint256 newReferencePrice = getRawPrice();
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
