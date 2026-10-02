// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.0;

/// @dev Subset of the Aave v4 `ISpoke`, `hub` and `flags` as their ABI types
interface ISpoke {
  struct Reserve {
    address underlying;
    address hub;
    uint16 assetId;
    uint8 decimals;
    uint24 collateralRisk;
    uint8 flags;
    uint32 dynamicConfigKey;
  }

  struct ReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
  }

  function getReserve(uint256 reserveId) external view returns (Reserve memory);

  function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);
}
