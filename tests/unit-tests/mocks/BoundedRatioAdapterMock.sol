// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {BoundedRatioAdapterBase, IChainlinkAggregator} from '../../../src/contracts/BoundedRatioAdapterBase.sol';

contract BoundedRatioAdapterMock is BoundedRatioAdapterBase {
  constructor(BoundedRatioAdapterParams memory params) BoundedRatioAdapterBase(params) {}

  function getRatio() public view override returns (int256) {
    return IChainlinkAggregator(RATIO_PROVIDER).latestAnswer();
  }
}
