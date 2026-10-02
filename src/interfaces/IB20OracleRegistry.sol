// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IB20OracleRegistry {
  /**
   * @notice Returns the issuer multiplier (18 decimals) of a B20 token and its pause flag
   * @dev Reverts for tokens without a multiplier
   */
  function getOracleParams(address token) external view returns (uint256 multiplier, bool paused);
}
