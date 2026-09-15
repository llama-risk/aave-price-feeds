// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IACLManager} from 'aave-address-book/AaveV3.sol';

import {IChainlinkAggregator} from './IChainlinkAggregator.sol';
import {ICLSynchronicityPriceAdapter} from './ICLSynchronicityPriceAdapter.sol';
import {IEquityMultiplier} from './IEquityMultiplier.sol';

interface IEquityPriceCapAdapter is ICLSynchronicityPriceAdapter {
  /**
   * @notice Parameters to create the adapter
   * @param assetToUsdAggregator Tokenized equity feed (TOKEN / USD), already total-return
   * @param equityMultiplier Contract implementing the per-issuer multiplier read, used only for
   *        the cross-check in `getImpliedUnderlyingPrice`
   * @param aclManager ACL manager of the pool, gates the bound setter
   * @param referenceUpdater Address allowed to advance the reference price, address(0) to disable
   * @param maxDeviationBps Maximum deviation from the reference price, in bps of the reference
   * @param minReferenceDelay Minimum seconds between two reference updates
   * @param description Description of the pair
   */
  struct EquityPriceCapAdapterParams {
    address assetToUsdAggregator;
    address equityMultiplier;
    address aclManager;
    address referenceUpdater;
    uint16 maxDeviationBps;
    uint32 minReferenceDelay;
    string description;
  }

  /**
   * @notice Emitted when the deviation bound is changed
   * @param oldMaxDeviationBps Previous bound
   * @param newMaxDeviationBps New bound
   */
  event MaxDeviationBpsUpdated(uint16 oldMaxDeviationBps, uint16 newMaxDeviationBps);

  /**
   * @notice Emitted when the reference price is advanced
   * @param oldReferencePrice Previous reference
   * @param newReferencePrice New reference
   * @param timestamp Time of the update
   */
  event ReferencePriceUpdated(
    uint256 oldReferencePrice,
    uint256 newReferencePrice,
    uint256 timestamp
  );

  /**
   * @notice Emitted when the address allowed to advance the reference is changed
   * @param oldReferenceUpdater Previous updater
   * @param newReferenceUpdater New updater
   */
  event ReferenceUpdaterUpdated(address oldReferenceUpdater, address newReferenceUpdater);

  /// @dev Attempted to set the zero address where a contract is required
  error ZeroAddress();

  /// @dev Attempted to set a deviation bound of zero, or above `MAX_DEVIATION_BPS_LIMIT`
  error InvalidMaxDeviationBps();

  /// @dev Attempted to call a permissioned function from an address that is neither admin
  error CallerIsNotRiskOrPoolAdmin();

  /// @dev Attempted to advance the reference from an address that is not the updater or an admin
  error CallerIsNotReferenceUpdater();

  /// @dev Attempted to advance the reference before `MIN_REFERENCE_DELAY` has elapsed
  error ReferenceUpdatedTooRecently();

  /// @dev Attempted to seed or advance the reference while the underlying price is unusable
  error InvalidReferencePrice();

  /// @dev The multiplier source reports a scale this adapter cannot represent safely
  error UnsupportedMultiplierDecimals();

  /// @notice Upper limit on the configurable deviation bound, in bps
  function MAX_DEVIATION_BPS_LIMIT() external view returns (uint16);

  /// @notice Basis-point denominator
  function BPS_DENOMINATOR() external view returns (uint256);

  /// @notice Tokenized equity feed, whose answer is already the total return value of the token
  function ASSET_TO_USD_AGGREGATOR() external view returns (IChainlinkAggregator);

  /// @notice Per-issuer multiplier source, read for the cross-check only, never for the price
  function EQUITY_MULTIPLIER() external view returns (IEquityMultiplier);

  /// @notice ACL manager of the pool
  function ACL_MANAGER() external view returns (IACLManager);

  /// @notice Fixed-point scale of the multiplier, read once at construction
  function MULTIPLIER_DECIMALS() external view returns (uint8);

  /// @notice Minimum seconds between two reference updates
  function MIN_REFERENCE_DELAY() external view returns (uint32);

  /// @notice Address allowed to advance the reference price
  function referenceUpdater() external view returns (address);

  /// @notice Current deviation bound, in bps of the reference price
  function maxDeviationBps() external view returns (uint16);

  /// @notice Reference price the bounds are measured against
  function referencePrice() external view returns (uint256);

  /// @notice Timestamp of the last reference update
  function referenceTimestamp() external view returns (uint48);

  /**
   * @notice The feed's answer, before the band is applied
   * @dev This is already the total return value of the token: the issuer multiplier is applied
   *      inside the feed, so nothing further is multiplied in here. Returns zero when the feed
   *      reports a non-positive answer. Exposed so the distance between the feed and the published
   *      price is observable without recomputing it.
   * @return The unbounded feed price in `decimals()`
   */
  function getFeedPrice() external view returns (uint256);

  /**
   * @notice The underlying share price implied by dividing the feed answer by the multiplier
   * @dev Purely a cross-check, never part of the published price. The feed applies the multiplier
   *      internally on its own schedule, so between an issuer writing a new multiplier and the
   *      feed picking it up, this value jumps by the corporate action's ratio. A discontinuity
   *      here means the two sides have diverged and the feed is briefly pricing the token against
   *      the wrong multiplier. Returns zero when either input is unusable.
   * @return The implied underlying share price in `decimals()`
   */
  function getImpliedUnderlyingPrice() external view returns (uint256);

  /**
   * @notice Current bounds derived from the reference price and the deviation
   * @return lowerBound Lowest price `latestAnswer` will publish
   * @return upperBound Highest price `latestAnswer` will publish
   */
  function getBounds() external view returns (uint256 lowerBound, uint256 upperBound);

  /**
   * @notice Whether the feed price currently falls outside the bounds
   * @dev True means `latestAnswer` is publishing a clamped price rather than the raw one.
   * @return Whether the published price is being clamped
   */
  function isCapped() external view returns (bool);

  /**
   * @notice Advances the reference price to the current feed price
   * @dev Callable by `referenceUpdater`, the risk admin or the pool admin, and no more often than
   *      `MIN_REFERENCE_DELAY`. The new reference is the feed price as-is, not the clamped one, so
   *      a stalled reference does not permanently anchor the band to an old level.
   */
  function updateReferencePrice() external;

  /**
   * @notice Sets the deviation bound
   * @dev Risk admin or pool admin only
   * @param newMaxDeviationBps New bound in bps, non-zero and at most `MAX_DEVIATION_BPS_LIMIT`
   */
  function setMaxDeviationBps(uint16 newMaxDeviationBps) external;

  /**
   * @notice Sets the address allowed to advance the reference price
   * @dev Risk admin or pool admin only. address(0) leaves the admins as the only callers.
   * @param newReferenceUpdater New updater
   */
  function setReferenceUpdater(address newReferenceUpdater) external;
}
