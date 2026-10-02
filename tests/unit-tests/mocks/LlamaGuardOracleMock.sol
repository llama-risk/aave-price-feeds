// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

contract LlamaGuardOracleMock {
  uint8 public decimals = 6;
  string public description = 'LlamaGuard NAV';
  uint80 public roundId;
  int256 public answer;
  uint256 public updatedAt;

  function setDecimals(uint8 decimals_) external {
    decimals = decimals_;
  }

  function setAnswer(int256 answer_) external {
    roundId++;
    answer = answer_;
    updatedAt = block.timestamp;
  }

  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
    return (roundId, answer, updatedAt, updatedAt, roundId);
  }
}
