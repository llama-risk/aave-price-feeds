// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {BoundedRatioAdapterBase, IACLManager, IPriceCapAdapter} from './BoundedRatioAdapterBase.sol';
import {ILlamaGuardOracle} from '../interfaces/ILlamaGuardOracle.sol';

/**
 * @title LlamaGuardNavAdapter
 * @author LlamaRisk
 * @notice Bounded price adapter for a NAV published on a LlamaGuardOracle.
 * @notice Answers in USD with 8 decimals, usable as an Aave v3 asset source and an Aave v4 price feed.
 */
contract LlamaGuardNavAdapter is BoundedRatioAdapterBase {
  error InvalidMaxNavAge();

  /**
   * @notice Maximum age of a NAV round; an older round is treated as no NAV
   * @dev At least `MAXIMUM_LOWER_BOUND_DURATION`, so a NAV below a lower bound is still fresh when the bound expires
   */
  uint48 public immutable MAX_NAV_AGE;

  /**
   * @notice Parameters to create adapter
   * @dev `navOracle` is a LlamaGuardOracle that answers the unbounded NAV in USD
   */
  struct LlamaGuardNavAdapterParams {
    IACLManager aclManager;
    address navOracle;
    string pairDescription;
    uint48 minimumSnapshotDelay;
    uint48 maximumLowerBoundDuration;
    uint48 maxNavAge;
    PriceCapUpdateParams priceCapParams;
  }

  /**
   * @param params parameters to create adapter
   */
  constructor(
    LlamaGuardNavAdapterParams memory params
  )
    BoundedRatioAdapterBase(
      BoundedRatioAdapterParams({
        aclManager: params.aclManager,
        baseAggregatorAddress: address(0),
        ratioProviderAddress: params.navOracle,
        pairDescription: params.pairDescription,
        ratioDecimals: _navDecimals(params.navOracle),
        minimumSnapshotDelay: params.minimumSnapshotDelay,
        maximumLowerBoundDuration: params.maximumLowerBoundDuration,
        priceCapParams: params.priceCapParams
      })
    )
  {
    if (params.maxNavAge == 0 || params.maxNavAge < params.maximumLowerBoundDuration) {
      revert InvalidMaxNavAge();
    }
    MAX_NAV_AGE = params.maxNavAge;
  }

  /// @inheritdoc IPriceCapAdapter
  /// @dev 0 when the round is invalid or older than `MAX_NAV_AGE`
  function getRatio() public view override returns (int256) {
    (int256 answer, ) = _getNav();
    return answer;
  }

  /// @dev The last good NAV timestamp when `getRatio` is 0
  function _getRatioUpdatedAt() internal view override returns (uint256) {
    (int256 answer, uint256 updatedAt) = _getNav();
    if (answer == 0) {
      (, updatedAt) = this.getLastGoodRatio();
    }
    return updatedAt;
  }

  function _getNav() internal view returns (int256, uint256) {
    (bool success, bytes memory data) = RATIO_PROVIDER.staticcall(
      abi.encodeCall(ILlamaGuardOracle.latestRoundData, ())
    );
    if (!success || data.length != 160) {
      return (0, 0);
    }
    (uint256 roundId, int256 answer, , uint256 updatedAt, uint256 answeredInRound) = abi.decode(
      data,
      (uint256, int256, uint256, uint256, uint256)
    );
    if (
      roundId > type(uint80).max ||
      answeredInRound > type(uint80).max ||
      answer <= 0 ||
      updatedAt > block.timestamp ||
      block.timestamp - updatedAt > MAX_NAV_AGE
    ) {
      return (0, 0);
    }
    return (answer, updatedAt);
  }

  function _navDecimals(address navOracle) private view returns (uint8) {
    if (navOracle == address(0)) {
      revert RatioProviderIsZeroAddress();
    }
    return ILlamaGuardOracle(navOracle).decimals();
  }
}
