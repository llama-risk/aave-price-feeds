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
  /**
   * @notice Parameters to create adapter
   * @dev `navOracle` is a LlamaGuardOracle that answers the NAV in USD
   */
  struct LlamaGuardNavAdapterParams {
    IACLManager aclManager;
    address navOracle;
    string pairDescription;
    uint48 minimumSnapshotDelay;
    uint48 maximumLowerBoundDuration;
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
  {}

  /// @inheritdoc IPriceCapAdapter
  function getRatio() public view override returns (int256) {
    (, int256 answer, , , ) = ILlamaGuardOracle(RATIO_PROVIDER).latestRoundData();
    return answer;
  }

  /// @dev 0 when the oracle reverts or returns malformed data
  function _getRatioUpdatedAt() internal view override returns (uint256) {
    (bool success, bytes memory data) = RATIO_PROVIDER.staticcall(
      abi.encodeCall(ILlamaGuardOracle.latestRoundData, ())
    );
    if (!success || data.length != 160) {
      return 0;
    }
    (, , , uint256 updatedAt, ) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
    return updatedAt;
  }

  function _navDecimals(address navOracle) private view returns (uint8) {
    if (navOracle == address(0)) {
      revert RatioProviderIsZeroAddress();
    }
    return ILlamaGuardOracle(navOracle).decimals();
  }
}
