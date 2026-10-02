// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IB20Token
 * @notice Minimal view surface of a B20 tokenized equity, limited to what pricing needs.
 * @dev Verified against the mag-7 tokens deployed on Base. `multiplier()` is selector 0x1b3ed722.
 */
interface IB20Token {
  /**
   * @notice Corporate-action multiplier, 18 decimals
   * @dev Moves on splits and reinvested dividends. Written directly by an operator role with no
   *      timelock, no staging and no bound on the step size.
   * @return The current multiplier
   */
  function multiplier() external view returns (uint256);
}
