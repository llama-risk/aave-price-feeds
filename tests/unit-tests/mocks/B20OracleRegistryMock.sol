// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

contract B20OracleRegistryMock {
  mapping(address => uint256) public multiplier;
  mapping(address => bool) public paused;
  bool public reverts;

  function setMultiplier(address token, uint256 multiplier_) external {
    multiplier[token] = multiplier_;
  }

  function setPaused(address token, bool paused_) external {
    paused[token] = paused_;
  }

  function setReverts(bool reverts_) external {
    reverts = reverts_;
  }

  function getOracleParams(address token) external view returns (uint256, bool) {
    require(!reverts && multiplier[token] != 0);
    return (multiplier[token], paused[token]);
  }
}
