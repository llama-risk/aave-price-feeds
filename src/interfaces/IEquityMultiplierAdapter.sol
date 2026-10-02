// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IBoundedRatioAdapter, IPriceCapAdapter, ICLSynchronicityPriceAdapter, IACLManager, IChainlinkAggregator} from './IBoundedRatioAdapter.sol';
import {ISpoke} from './ISpoke.sol';

interface IEquityMultiplierAdapter is IBoundedRatioAdapter {
  /**
   * @notice Parameters to create adapter
   * @dev `baseAggregatorAddress` prices the share without the multiplier; `spoke` and `reserveId` locate the v4 reserve of `token`
   */
  struct EquityMultiplierAdapterParams {
    IACLManager aclManager;
    address baseAggregatorAddress;
    address registry;
    address token;
    address spoke;
    uint256 reserveId;
    string pairDescription;
    uint48 minimumSnapshotDelay;
    uint48 maximumLowerBoundDuration;
    uint16 maximumYearlyRatioGrowthPercent;
    PriceCapUpdateParams priceCapParams;
  }

  /**
   * @notice B20 token priced by this adapter
   */
  function TOKEN() external view returns (address);

  /**
   * @notice v4 spoke holding the reserve of `TOKEN`
   */
  function SPOKE() external view returns (ISpoke);

  /**
   * @notice Reserve id of `TOKEN` on `SPOKE`
   */
  function RESERVE_ID() external view returns (uint256);

  /**
   * @notice Highest yearly growth of the upper bound a cap update can set
   */
  function MAXIMUM_YEARLY_RATIO_GROWTH_PERCENT() external view returns (uint16);

  /**
   * @notice Returns if the reserve is paused on `SPOKE`, false if the spoke read fails
   */
  function isReservePaused() external view returns (bool);

  /**
   * @notice Returns if the issuer registry flags the multiplier of `TOKEN` as paused, false if the read fails
   */
  function isIssuerPaused() external view returns (bool);

  error BaseAggregatorIsZeroAddress();
  error TokenIsZeroAddress();
  error ReserveUnderlyingMismatch(address underlying);
  error InvalidMultiplier();
  error MaxYearlyRatioGrowthPercentAboveLimit(uint16 maxYearlyRatioGrowthPercent);
  error SnapshotRatioOutsideWindow(uint256 snapshotRatio);
  error MaxRatioIncrease(uint256 maxRatio);
  error IssuerPaused();
}
