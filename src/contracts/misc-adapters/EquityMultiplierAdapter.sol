// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IB20OracleRegistry} from '../../interfaces/IB20OracleRegistry.sol';
import {ISpoke} from '../../interfaces/ISpoke.sol';
import {IEquityMultiplierAdapter, IBoundedRatioAdapter, IPriceCapAdapter} from '../../interfaces/IEquityMultiplierAdapter.sol';

import {BoundedRatioAdapterBase} from '../BoundedRatioAdapterBase.sol';

/**
 * @title EquityMultiplierAdapter
 * @author LlamaRisk
 * @notice Prices a B20 tokenized equity as (share / USD) x issuer multiplier.
 * @notice The multiplier is capped by a slowly growing upper bound. A multiplier below the last accepted one,
 * @notice above the upper bound, or flagged by the issuer is reported as a breach. Larger moves of the accepted
 * @notice multiplier are possible only while the v4 reserve is paused.
 */
contract EquityMultiplierAdapter is BoundedRatioAdapterBase, IEquityMultiplierAdapter {
  /// @inheritdoc IEquityMultiplierAdapter
  address public immutable TOKEN;

  /// @inheritdoc IEquityMultiplierAdapter
  ISpoke public immutable SPOKE;

  /// @inheritdoc IEquityMultiplierAdapter
  uint256 public immutable RESERVE_ID;

  /// @inheritdoc IEquityMultiplierAdapter
  uint16 public immutable MAXIMUM_YEARLY_RATIO_GROWTH_PERCENT;

  /**
   * @param params parameters to create adapter
   */
  constructor(
    EquityMultiplierAdapterParams memory params
  )
    BoundedRatioAdapterBase(
      BoundedRatioAdapterParams({
        aclManager: params.aclManager,
        baseAggregatorAddress: params.baseAggregatorAddress,
        ratioProviderAddress: params.registry,
        pairDescription: params.pairDescription,
        ratioDecimals: 18,
        minimumSnapshotDelay: params.minimumSnapshotDelay,
        maximumLowerBoundDuration: params.maximumLowerBoundDuration,
        priceCapParams: params.priceCapParams
      })
    )
  {
    if (params.baseAggregatorAddress == address(0)) {
      revert BaseAggregatorIsZeroAddress();
    }

    if (params.token == address(0)) {
      revert TokenIsZeroAddress();
    }

    address underlying = ISpoke(params.spoke).getReserve(params.reserveId).underlying;
    if (underlying != params.token) {
      revert ReserveUnderlyingMismatch(underlying);
    }

    (uint256 multiplier, ) = IB20OracleRegistry(params.registry).getOracleParams(params.token);
    if (multiplier == 0 || multiplier > type(uint104).max) {
      revert InvalidMultiplier();
    }

    if (params.priceCapParams.snapshotRatio > multiplier) {
      revert SnapshotRatioOutsideWindow(params.priceCapParams.snapshotRatio);
    }

    if (
      params.priceCapParams.maxYearlyRatioGrowthPercent > params.maximumYearlyRatioGrowthPercent
    ) {
      revert MaxYearlyRatioGrowthPercentAboveLimit(
        params.priceCapParams.maxYearlyRatioGrowthPercent
      );
    }

    TOKEN = params.token;
    SPOKE = ISpoke(params.spoke);
    RESERVE_ID = params.reserveId;
    MAXIMUM_YEARLY_RATIO_GROWTH_PERCENT = params.maximumYearlyRatioGrowthPercent;
  }

  /// @inheritdoc IPriceCapAdapter
  function getRatio()
    public
    view
    override(BoundedRatioAdapterBase, IPriceCapAdapter)
    returns (int256)
  {
    (uint256 multiplier, ) = IB20OracleRegistry(RATIO_PROVIDER).getOracleParams(TOKEN);
    // forge-lint: disable-next-line(unsafe-typecast)
    return int256(multiplier);
  }

  /// @inheritdoc IEquityMultiplierAdapter
  function isReservePaused() public view returns (bool) {
    try SPOKE.getReserveConfig(RESERVE_ID) returns (ISpoke.ReserveConfig memory config) {
      return config.paused;
    } catch {
      return false;
    }
  }

  /// @inheritdoc IEquityMultiplierAdapter
  function isIssuerPaused() public view returns (bool) {
    try IB20OracleRegistry(RATIO_PROVIDER).getOracleParams(TOKEN) returns (uint256, bool paused) {
      return paused;
    } catch {
      return false;
    }
  }

  /// @inheritdoc IBoundedRatioAdapter
  function isBreached()
    public
    view
    override(BoundedRatioAdapterBase, IBoundedRatioAdapter)
    returns (bool)
  {
    uint256 ratio = _getRawRatio();
    return ratio == 0 || ratio < getSnapshotRatio() || ratio > getMaxRatio() || isIssuerPaused();
  }

  function _getRatioUpdatedAt() internal view override returns (uint256) {
    return _getBaseUpdatedAt();
  }

  /// @dev A multiplier drop is priced as is, never above the raw multiplier
  function _getMinRatio(uint256 ratio) internal view override returns (uint256) {
    if (ratio != 0) {
      return 0;
    }

    uint256 lowerBound = getActiveLowerBound();
    uint256 snapshotRatio = getSnapshotRatio();
    return lowerBound < snapshotRatio ? lowerBound : snapshotRatio;
  }

  function _getLowerBoundLimit(uint256 ratio) internal view override returns (uint256) {
    return ratio == 0 ? getSnapshotRatio() : ratio;
  }

  function _validateCapParameters(
    PriceCapUpdateParams memory priceCapParams
  ) internal view override {
    if (priceCapParams.maxYearlyRatioGrowthPercent > MAXIMUM_YEARLY_RATIO_GROWTH_PERCENT) {
      revert MaxYearlyRatioGrowthPercentAboveLimit(priceCapParams.maxYearlyRatioGrowthPercent);
    }

    if (isReservePaused()) {
      return;
    }

    if (isIssuerPaused()) {
      revert IssuerPaused();
    }

    if (
      priceCapParams.snapshotRatio < getSnapshotRatio() ||
      priceCapParams.snapshotRatio > _getRawRatio()
    ) {
      revert SnapshotRatioOutsideWindow(priceCapParams.snapshotRatio);
    }

    uint256 elapsed = block.timestamp > priceCapParams.snapshotTimestamp
      ? block.timestamp - priceCapParams.snapshotTimestamp
      : 0;
    uint256 growthPerSecondScaled = (uint256(priceCapParams.snapshotRatio) *
      priceCapParams.maxYearlyRatioGrowthPercent *
      SCALING_FACTOR) /
      PERCENTAGE_FACTOR /
      SECONDS_PER_YEAR;
    uint256 maxRatio = priceCapParams.snapshotRatio +
      (growthPerSecondScaled * elapsed) /
      SCALING_FACTOR;
    if (maxRatio > getMaxRatio()) {
      revert MaxRatioIncrease(maxRatio);
    }
  }
}
