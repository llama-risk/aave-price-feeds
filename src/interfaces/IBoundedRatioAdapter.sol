// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IPriceCapAdapter, ICLSynchronicityPriceAdapter, IACLManager, IChainlinkAggregator} from './IPriceCapAdapter.sol';

interface IBoundedRatioAdapter is IPriceCapAdapter {
  /**
   * @dev Emitted when the lower bound is updated
   * @param lowerBound the minimum ratio used while the bound is active
   * @param expiration the timestamp from which the bound no longer applies
   *
   */
  event LowerBoundUpdated(uint256 lowerBound, uint256 expiration);

  /**
   * @notice Parameters to create adapter
   * @dev `baseAggregatorAddress` is optional: with address(0) the ratio is priced on its own
   */
  struct BoundedRatioAdapterParams {
    IACLManager aclManager;
    address baseAggregatorAddress;
    address ratioProviderAddress;
    string pairDescription;
    uint8 ratioDecimals;
    uint48 minimumSnapshotDelay;
    uint48 maximumLowerBoundDuration;
    PriceCapUpdateParams priceCapParams;
  }

  /**
   * @notice Sets the lower bound of the ratio until `expiration`
   * @param lowerBound minimum ratio, at most the currently bounded ratio
   * @param expiration timestamp from which the bound no longer applies
   */
  function setLowerBound(uint104 lowerBound, uint48 expiration) external;

  /**
   * @notice Maximum time (in seconds) a lower bound can stay active after it is set
   */
  function MAXIMUM_LOWER_BOUND_DURATION() external view returns (uint48);

  /**
   * @notice Returns the stored lower bound and its expiration, active or not
   */
  function getLowerBound() external view returns (uint256 lowerBound, uint256 expiration);

  /**
   * @notice Returns the lower bound if it has not expired, 0 otherwise
   */
  function getActiveLowerBound() external view returns (uint256);

  /**
   * @notice Returns the upper bound of the ratio at the current timestamp
   */
  function getMaxRatio() external view returns (uint256);

  /**
   * @notice Returns the ratio used for the price, 0 if no valid ratio is available
   */
  function getBoundedRatio() external view returns (uint256);

  /**
   * @notice Returns if the active lower bound sets the ratio
   */
  function isFloored() external view returns (bool);

  /**
   * @notice Returns if the raw ratio is invalid or outside the active bounds
   */
  function isBreached() external view returns (bool);

  /**
   * @notice Returns the latest answer in the AggregatorV3 format
   */
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  error RatioProviderIsZeroAddress();
  error InvalidLowerBound(uint256 lowerBound);
  error InvalidLowerBoundExpiration(uint48 expiration);
  error InvalidLowerBoundDuration();
}
