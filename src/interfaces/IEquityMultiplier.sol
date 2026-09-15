// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IEquityMultiplier
 * @author LlamaRisk
 * @notice The per-issuer read behind which every tokenized equity multiplier is normalised.
 * @dev A tokenized equity's on-chain price is the price of the underlying share multiplied by an
 *      issuer-published multiplier that absorbs corporate actions: a 3-for-1 split takes it from
 *      1.0 to 3.0, a reinvested dividend nudges it up by the dividend's share of the price.
 *
 *      Issuers expose this differently, so each gets a thin adapter implementing this interface
 *      and the pricing contract stays issuer-agnostic. Implementations must return the multiplier
 *      scaled to `multiplierDecimals()`, which is read once at construction and assumed constant.
 */
interface IEquityMultiplier {
  /**
   * @notice Current issuer multiplier, scaled to `multiplierDecimals()`
   * @dev Must revert rather than return a stale or default value if the issuer read fails.
   *      Returning zero is treated by consumers as an invalid price, not as a zero multiplier.
   * @return The multiplier applied to the underlying share price
   */
  function multiplier() external view returns (uint256);

  /**
   * @notice Fixed-point scale of the value returned by `multiplier()`
   * @dev Read once at construction by the pricing contract. An issuer that changed this after
   *      deployment would silently rescale every price, so implementations must treat it as
   *      immutable.
   * @return Number of decimals
   */
  function multiplierDecimals() external view returns (uint8);
}
