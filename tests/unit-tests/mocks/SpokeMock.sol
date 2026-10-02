// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {ISpoke} from '../../../src/interfaces/ISpoke.sol';

contract SpokeMock {
  mapping(uint256 => address) public underlying;
  mapping(uint256 => bool) public paused;
  bool public reverts;

  function setUnderlying(uint256 reserveId, address underlying_) external {
    underlying[reserveId] = underlying_;
  }

  function setPaused(uint256 reserveId, bool paused_) external {
    paused[reserveId] = paused_;
  }

  function setReverts(bool reverts_) external {
    reverts = reverts_;
  }

  function getReserve(uint256 reserveId) external view returns (ISpoke.Reserve memory reserve) {
    require(underlying[reserveId] != address(0));
    reserve.underlying = underlying[reserveId];
  }

  function getReserveConfig(
    uint256 reserveId
  ) external view returns (ISpoke.ReserveConfig memory config) {
    require(!reverts && underlying[reserveId] != address(0));
    config.paused = paused[reserveId];
  }
}
