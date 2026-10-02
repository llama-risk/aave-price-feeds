// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {BoundedRatioAdapterBase, IChainlinkAggregator} from '../../../src/contracts/BoundedRatioAdapterBase.sol';

contract BoundedRatioAdapterMock is BoundedRatioAdapterBase {
  constructor(BoundedRatioAdapterParams memory params) BoundedRatioAdapterBase(params) {}

  function getRatio() public view override returns (int256) {
    return IChainlinkAggregator(RATIO_PROVIDER).latestAnswer();
  }

  function _getRatioUpdatedAt() internal view override returns (uint256) {
    return IChainlinkAggregator(RATIO_PROVIDER).latestTimestamp();
  }
}

contract BoundedRatioAdapterHooksMock is BoundedRatioAdapterMock {
  error CapUpdateRejected();

  uint256 public minRatio;
  uint256 public lowerBoundLimit;
  bool public rejectCapUpdate;
  bool public breached;

  constructor(BoundedRatioAdapterParams memory params) BoundedRatioAdapterMock(params) {}

  function setHooks(
    uint256 minRatio_,
    uint256 lowerBoundLimit_,
    bool rejectCapUpdate_,
    bool breached_
  ) external {
    minRatio = minRatio_;
    lowerBoundLimit = lowerBoundLimit_;
    rejectCapUpdate = rejectCapUpdate_;
    breached = breached_;
  }

  function isBreached() public view override returns (bool) {
    return breached || super.isBreached();
  }

  function _getMinRatio(uint256) internal view override returns (uint256) {
    return minRatio;
  }

  function _getLowerBoundLimit(uint256) internal view override returns (uint256) {
    return lowerBoundLimit;
  }

  function _validateCapParameters(PriceCapUpdateParams memory) internal view override {
    if (rejectCapUpdate) {
      revert CapUpdateRejected();
    }
  }
}
