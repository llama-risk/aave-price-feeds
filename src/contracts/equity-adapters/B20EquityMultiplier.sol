// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IEquityMultiplier} from '../../interfaces/IEquityMultiplier.sol';
import {IB20Token} from '../../interfaces/IB20Token.sol';

/**
 * @title B20EquityMultiplier
 * @author LlamaRisk
 * @notice Reads the corporate-action multiplier from a B20 tokenized equity on Base.
 * @dev B20 exposes `multiplier()` directly on the token at 18 decimals, so this is a pass-through.
 *      It exists as its own contract so the pricing adapter never learns an issuer's ABI: the next
 *      issuer ships another one of these and nothing else changes.
 *
 *      Two properties of the B20 multiplier shape the layer above.
 *
 *      It is written directly by an operator role with no timelock, no staging and no bound on the
 *      step, so a compromised operator moves it in a single transaction. Announcements exist but
 *      are optional and atomic, emitted in the same transaction as the change, so they carry no
 *      lead time. Detection is therefore polling plus the deviation band, not an event listener.
 *
 *      It is not uniformly 1.0 across the mag-7. On Base at the time of writing six tokens read
 *      exactly 1e18 while GOOGLc reads 1000377118676784000, consistent with a dividend already
 *      having flowed through. Anything asserting a multiplier of exactly 1e18 is wrong on the
 *      first read.
 */
contract B20EquityMultiplier is IEquityMultiplier {
  /// @dev B20 publishes the multiplier at 18 decimals
  uint8 internal constant B20_MULTIPLIER_DECIMALS = 18;

  /// @notice The B20 token this reads from
  IB20Token public immutable TOKEN;

  /// @dev Attempted to set the zero address
  error ZeroAddress();

  /// @dev The token returned a zero multiplier, which is never a valid corporate-action state
  error InvalidMultiplier();

  /**
   * @param token address of the B20 tokenized equity
   */
  constructor(address token) {
    if (token == address(0)) {
      revert ZeroAddress();
    }

    TOKEN = IB20Token(token);

    // Fail at deployment rather than at the first price read.
    if (TOKEN.multiplier() == 0) {
      revert InvalidMultiplier();
    }
  }

  /// @inheritdoc IEquityMultiplier
  function multiplier() external view returns (uint256) {
    return TOKEN.multiplier();
  }

  /// @inheritdoc IEquityMultiplier
  function multiplierDecimals() external pure returns (uint8) {
    return B20_MULTIPLIER_DECIMALS;
  }
}
