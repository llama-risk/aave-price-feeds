// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IBoundedRatioAdapter, IPriceCapAdapter, ICLSynchronicityPriceAdapter, IACLManager, IChainlinkAggregator} from '../interfaces/IBoundedRatioAdapter.sol';

/**
 * @title BoundedRatioAdapterBase
 * @author LlamaRisk
 * @notice Price adapter that clamps a ratio between a growing upper bound and an expiring lower bound,
 * @notice optionally priced against a base feed. Answers with 8 decimals.
 */
abstract contract BoundedRatioAdapterBase is IBoundedRatioAdapter {
  /// @inheritdoc IPriceCapAdapter
  uint256 public constant PERCENTAGE_FACTOR = 1e4;

  /// @inheritdoc IPriceCapAdapter
  uint256 public constant SCALING_FACTOR = 1e6;

  /// @inheritdoc IPriceCapAdapter
  uint256 public constant SECONDS_PER_YEAR = 365 days;

  /// @inheritdoc IPriceCapAdapter
  uint8 public constant DECIMALS = 8;

  /// @inheritdoc IPriceCapAdapter
  IChainlinkAggregator public immutable BASE_TO_USD_AGGREGATOR;

  /// @inheritdoc IPriceCapAdapter
  IACLManager public immutable ACL_MANAGER;

  /// @inheritdoc IPriceCapAdapter
  address public immutable RATIO_PROVIDER;

  /// @inheritdoc IPriceCapAdapter
  uint8 public immutable RATIO_DECIMALS;

  /// @inheritdoc IPriceCapAdapter
  uint48 public immutable MINIMUM_SNAPSHOT_DELAY;

  /// @inheritdoc IPriceCapAdapter
  uint48 public immutable MAXIMUM_SNAPSHOT_TERM = 180 days;

  /// @inheritdoc IBoundedRatioAdapter
  uint48 public immutable MAXIMUM_LOWER_BOUND_DURATION;

  uint256 internal immutable _SCALE_UP;

  uint256 internal immutable _SCALE_DOWN;

  string private _description;

  uint104 private _snapshotRatio;

  uint48 private _snapshotTimestamp;

  uint104 private _maxRatioGrowthPerSecondScaled;

  uint16 private _maxYearlyRatioGrowthPercent;

  uint104 private _lowerBound;

  uint48 private _lowerBoundExpiration;

  uint104 private _lastGoodRatio;

  uint48 private _lastGoodRatioTimestamp;

  /**
   * @param params parameters to create adapter
   */
  constructor(BoundedRatioAdapterParams memory params) {
    if (address(params.aclManager) == address(0)) {
      revert ACLManagerIsZeroAddress();
    }

    if (params.ratioProviderAddress == address(0)) {
      revert RatioProviderIsZeroAddress();
    }

    if (params.ratioDecimals < 6 || params.ratioDecimals > 24) {
      revert WrongRatioDecimals();
    }

    if (
      params.maximumLowerBoundDuration == 0 ||
      params.maximumLowerBoundDuration > MAXIMUM_SNAPSHOT_TERM
    ) {
      revert InvalidLowerBoundDuration();
    }

    uint8 baseDecimals;
    if (params.baseAggregatorAddress != address(0)) {
      baseDecimals = IChainlinkAggregator(params.baseAggregatorAddress).decimals();
      if (baseDecimals > 24) {
        revert DecimalsAboveLimit();
      }
    }

    ACL_MANAGER = params.aclManager;
    BASE_TO_USD_AGGREGATOR = IChainlinkAggregator(params.baseAggregatorAddress);
    RATIO_PROVIDER = params.ratioProviderAddress;
    RATIO_DECIMALS = params.ratioDecimals;
    MINIMUM_SNAPSHOT_DELAY = params.minimumSnapshotDelay;
    MAXIMUM_LOWER_BOUND_DURATION = params.maximumLowerBoundDuration;

    uint256 inputDecimals = uint256(params.ratioDecimals) + baseDecimals;
    _SCALE_UP = inputDecimals < DECIMALS ? 10 ** (DECIMALS - inputDecimals) : 1;
    _SCALE_DOWN = inputDecimals > DECIMALS ? 10 ** (inputDecimals - DECIMALS) : 1;

    _description = params.pairDescription;

    _setCapParameters(params.priceCapParams);
  }

  /// @inheritdoc ICLSynchronicityPriceAdapter
  function description() external view returns (string memory) {
    return _description;
  }

  /// @inheritdoc ICLSynchronicityPriceAdapter
  function decimals() external pure returns (uint8) {
    return DECIMALS;
  }

  /// @inheritdoc IPriceCapAdapter
  function getSnapshotRatio() public view returns (uint256) {
    return _snapshotRatio;
  }

  /// @inheritdoc IPriceCapAdapter
  function getSnapshotTimestamp() public view returns (uint256) {
    return _snapshotTimestamp;
  }

  /// @inheritdoc IPriceCapAdapter
  function getMaxYearlyGrowthRatePercent() external view returns (uint256) {
    return _maxYearlyRatioGrowthPercent;
  }

  /// @inheritdoc IPriceCapAdapter
  function getMaxRatioGrowthPerSecond() external view returns (uint256) {
    return _maxRatioGrowthPerSecondScaled / SCALING_FACTOR;
  }

  /// @inheritdoc IPriceCapAdapter
  function getMaxRatioGrowthPerSecondScaled() external view returns (uint256) {
    return _maxRatioGrowthPerSecondScaled;
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getLowerBound() external view returns (uint256, uint256) {
    return (_lowerBound, _lowerBoundExpiration);
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getActiveLowerBound() public view returns (uint256) {
    return block.timestamp < _lowerBoundExpiration ? _lowerBound : 0;
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getLowerBoundLimit() public view returns (uint256) {
    uint256 limit = _getLowerBoundLimit(_getRawRatio());
    uint256 maxRatio = getMaxRatio();
    return limit > maxRatio ? maxRatio : limit;
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getLastGoodRatio() external view returns (uint256, uint256) {
    return (_lastGoodRatio, _lastGoodRatioTimestamp);
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getLastGoodRatioAge() external view returns (uint256) {
    return _lastGoodRatio == 0 ? type(uint256).max : block.timestamp - _lastGoodRatioTimestamp;
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getMaxRatio() public view returns (uint256) {
    return
      _snapshotRatio +
      (_maxRatioGrowthPerSecondScaled * (block.timestamp - _snapshotTimestamp)) /
      SCALING_FACTOR;
  }

  /// @inheritdoc IBoundedRatioAdapter
  function getBoundedRatio() public view returns (uint256 ratio) {
    (ratio, ) = _getBoundedRatio();
  }

  /// @inheritdoc IBoundedRatioAdapter
  function isHeld() external view returns (bool held) {
    (, held) = _getBoundedRatio();
  }

  /// @inheritdoc IPriceCapAdapter
  function getRatio() public view virtual returns (int256);

  /// @inheritdoc IPriceCapAdapter
  function isCapped() public view returns (bool) {
    return _getRawRatio() > getMaxRatio();
  }

  /// @inheritdoc IBoundedRatioAdapter
  function isFloored() public view returns (bool) {
    uint256 ratio = _getRawRatio();
    return ratio < _getMinRatio(ratio);
  }

  /// @inheritdoc IBoundedRatioAdapter
  function isBreached() public view virtual returns (bool) {
    uint256 ratio = _getRawRatio();
    return ratio == 0 || ratio < _getMinRatio(ratio) || ratio > getMaxRatio();
  }

  /// @inheritdoc ICLSynchronicityPriceAdapter
  function latestAnswer() public view returns (int256 answer) {
    (answer, ) = _getAnswer();
  }

  /// @inheritdoc IBoundedRatioAdapter
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    bool held;
    (answer, held) = _getAnswer();
    if (answer > 0) {
      updatedAt = _getUpdatedAt(held ? _lastGoodRatioTimestamp : _getRatioUpdatedAt());
    }
    return (0, answer, updatedAt, updatedAt, 0);
  }

  /// @inheritdoc IBoundedRatioAdapter
  function recordRatio() external returns (uint256 ratio) {
    ratio = _recordRatio();
    if (ratio == 0) {
      revert NoValidRatio();
    }
  }

  /// @inheritdoc IPriceCapAdapter
  function setCapParameters(PriceCapUpdateParams memory priceCapParams) external {
    _onlyRiskOrPoolAdmin();

    _validateCapParameters(priceCapParams);
    _setCapParameters(priceCapParams);
    _recordRatio();
  }

  /// @inheritdoc IBoundedRatioAdapter
  function setLowerBound(uint104 lowerBound, uint48 expiration) external {
    _onlyRiskOrPoolAdmin();

    if (
      expiration <= block.timestamp || expiration > block.timestamp + MAXIMUM_LOWER_BOUND_DURATION
    ) {
      revert InvalidLowerBoundExpiration(expiration);
    }

    if (lowerBound > getLowerBoundLimit()) {
      revert InvalidLowerBound(lowerBound);
    }

    // record against the previous bound, so a new bound cannot unfloor a breached ratio
    _recordRatio();

    _lowerBound = lowerBound;
    _lowerBoundExpiration = expiration;

    emit LowerBoundUpdated(lowerBound, expiration);
  }

  /// @dev Timestamp of the latest ratio update, must not revert
  function _getRatioUpdatedAt() internal view virtual returns (uint256);

  /// @dev Lowest ratio used for the price, given the raw ratio (0 when invalid)
  function _getMinRatio(uint256) internal view virtual returns (uint256) {
    return getActiveLowerBound();
  }

  /// @dev Highest lower bound that can be set, given the raw ratio (0 when invalid); capped by the upper bound
  function _getLowerBoundLimit(uint256 ratio) internal view virtual returns (uint256) {
    return ratio == 0 ? _lowerBound : ratio;
  }

  /// @dev Extra checks on a cap update, run before the stored parameters change
  function _validateCapParameters(PriceCapUpdateParams memory) internal view virtual {}

  /// @dev Ratio used for the price, and whether it is the last good ratio
  function _getBoundedRatio() internal view returns (uint256 ratio, bool held) {
    ratio = _getRawRatio();
    uint256 minRatio = _getMinRatio(ratio);
    if (ratio < minRatio) {
      ratio = minRatio;
    }

    if (ratio == 0) {
      ratio = _lastGoodRatio;
      held = ratio != 0;
    }

    uint256 maxRatio = getMaxRatio();
    if (ratio > maxRatio) {
      ratio = maxRatio;
    }
  }

  function _getAnswer() internal view returns (int256, bool) {
    (uint256 ratio, bool held) = _getBoundedRatio();
    if (ratio == 0) {
      return (0, held);
    }

    uint256 basePrice = 1;
    if (address(BASE_TO_USD_AGGREGATOR) != address(0)) {
      basePrice = _getBasePrice();
      if (basePrice == 0) {
        return (0, held);
      }
    }

    // forge-lint: disable-next-line(unsafe-typecast)
    return (int256((basePrice * ratio * _SCALE_UP) / _SCALE_DOWN), held);
  }

  /// @dev Stores the valid, non-floored raw ratio, capped by the upper bound, with the ratio source timestamp.
  /// Skips (returns 0) when the ratio is invalid or floored, or its timestamp is older than the stored one
  function _recordRatio() internal returns (uint256) {
    uint256 ratio = _getRawRatio();
    if (ratio == 0 || ratio < _getMinRatio(ratio)) {
      return 0;
    }

    uint256 maxRatio = getMaxRatio();
    if (ratio > maxRatio) {
      ratio = maxRatio;
    }
    if (ratio > type(uint104).max) {
      ratio = type(uint104).max;
    }

    uint256 updatedAt = _getRatioUpdatedAt();
    if (updatedAt == 0 || updatedAt > block.timestamp) {
      updatedAt = block.timestamp;
    }
    if (updatedAt < _lastGoodRatioTimestamp) {
      return 0;
    }

    // forge-lint: disable-next-line(unsafe-typecast)
    _lastGoodRatio = uint104(ratio);
    // forge-lint: disable-next-line(unsafe-typecast)
    _lastGoodRatioTimestamp = uint48(updatedAt);

    emit LastGoodRatioRecorded(ratio, updatedAt);
    return ratio;
  }

  function _getUpdatedAt(uint256 ratioUpdatedAt) internal view returns (uint256) {
    uint256 updatedAt = ratioUpdatedAt;
    if (address(BASE_TO_USD_AGGREGATOR) != address(0)) {
      uint256 baseUpdatedAt = _getBaseUpdatedAt();
      if (baseUpdatedAt < updatedAt) {
        updatedAt = baseUpdatedAt;
      }
    }
    return updatedAt;
  }

  /// @dev 0 when the feed reverts or returns malformed data
  function _getBaseUpdatedAt() internal view returns (uint256) {
    (bool success, bytes memory data) = address(BASE_TO_USD_AGGREGATOR).staticcall(
      abi.encodeCall(IChainlinkAggregator.latestTimestamp, ())
    );
    if (!success || data.length != 32) {
      return 0;
    }
    return abi.decode(data, (uint256));
  }

  /// @dev 0 when the provider reverts or returns a non-positive ratio
  function _getRawRatio() internal view returns (uint256) {
    try this.getRatio() returns (int256 ratio) {
      // forge-lint: disable-next-line(unsafe-typecast)
      return ratio > 0 ? uint256(ratio) : 0;
    } catch {
      return 0;
    }
  }

  /// @dev 0 when the feed reverts or returns a price outside (0, 2^128]
  function _getBasePrice() internal view returns (uint256) {
    (bool success, bytes memory data) = address(BASE_TO_USD_AGGREGATOR).staticcall(
      abi.encodeCall(IChainlinkAggregator.latestAnswer, ())
    );
    if (!success || data.length != 32) {
      return 0;
    }

    int256 price = abi.decode(data, (int256));
    if (price <= 0 || price > int256(uint256(type(uint128).max))) {
      return 0;
    }

    // forge-lint: disable-next-line(unsafe-typecast)
    return uint256(price);
  }

  function _onlyRiskOrPoolAdmin() internal view {
    if (!ACL_MANAGER.isRiskAdmin(msg.sender) && !ACL_MANAGER.isPoolAdmin(msg.sender)) {
      revert CallerIsNotRiskOrPoolAdmin();
    }
  }

  function _setCapParameters(PriceCapUpdateParams memory priceCapParams) internal {
    if (priceCapParams.snapshotRatio == 0) {
      revert SnapshotRatioIsZero();
    }

    if (
      _snapshotTimestamp >= priceCapParams.snapshotTimestamp ||
      priceCapParams.snapshotTimestamp > block.timestamp - MINIMUM_SNAPSHOT_DELAY ||
      priceCapParams.snapshotTimestamp < block.timestamp - MAXIMUM_SNAPSHOT_TERM
    ) {
      revert InvalidRatioTimestamp(priceCapParams.snapshotTimestamp);
    }

    _snapshotRatio = priceCapParams.snapshotRatio;
    _snapshotTimestamp = priceCapParams.snapshotTimestamp;
    _maxYearlyRatioGrowthPercent = priceCapParams.maxYearlyRatioGrowthPercent;

    uint256 maxRatioGrowthPerSecondScaled = (uint256(priceCapParams.snapshotRatio) *
      priceCapParams.maxYearlyRatioGrowthPercent *
      SCALING_FACTOR) /
      PERCENTAGE_FACTOR /
      SECONDS_PER_YEAR;

    // forge-lint: disable-next-line(unsafe-typecast)
    _maxRatioGrowthPerSecondScaled = uint104(maxRatioGrowthPerSecondScaled);

    emit CapParametersUpdated(
      priceCapParams.snapshotRatio,
      priceCapParams.snapshotTimestamp,
      maxRatioGrowthPerSecondScaled / SCALING_FACTOR,
      priceCapParams.maxYearlyRatioGrowthPercent
    );
  }
}
