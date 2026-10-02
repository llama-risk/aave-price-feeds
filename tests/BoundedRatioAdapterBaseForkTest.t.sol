// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from 'forge-std/Test.sol';
import {AaveV3Base, AaveV3BaseAssets} from 'aave-address-book/AaveV3Base.sol';
import {ChainlinkBase} from 'aave-address-book/ChainlinkBase.sol';

import {IBoundedRatioAdapter, IPriceCapAdapter, IChainlinkAggregator} from '../src/interfaces/IBoundedRatioAdapter.sol';
import {BoundedRatioAdapterMock} from './unit-tests/mocks/BoundedRatioAdapterMock.sol';

interface IAaveV4Oracle {
  function setReserveSource(uint256 reserveId, address source) external;

  function getReservePrice(uint256 reserveId) external view returns (uint256);

  error InvalidPrice(uint256 reserveId);
}

contract BoundedRatioAdapterBaseForkTest is Test {
  IAaveV4Oracle public constant MAG7_SPOKE_ORACLE =
    IAaveV4Oracle(0xaBaf048fD7675Ea34a84332371ffd5D55E322A47);
  address public constant MAG7_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
  address public constant MAG7_SPOKE_AAPLc_PRICE_FEED = 0x787f13dEa48Db0897CbCDD985de77809D837F988;
  uint256 public constant AAPLc_RESERVE_ID = 0;

  address public boundsAgent = makeAddr('boundsAgent');

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('base'), 52044276);

    vm.prank(AaveV3Base.ACL_ADMIN);
    AaveV3Base.ACL_MANAGER.addRiskAdmin(boundsAgent);
  }

  function _deploy(
    address base,
    address ratioProvider,
    uint16 maxYearlyGrowth
  ) internal returns (BoundedRatioAdapterMock) {
    uint256 ratio = uint256(IChainlinkAggregator(ratioProvider).latestAnswer());
    return
      new BoundedRatioAdapterMock(
        IBoundedRatioAdapter.BoundedRatioAdapterParams({
          aclManager: AaveV3Base.ACL_MANAGER,
          baseAggregatorAddress: base,
          ratioProviderAddress: ratioProvider,
          pairDescription: 'Bounded test feed',
          ratioDecimals: IChainlinkAggregator(ratioProvider).decimals(),
          minimumSnapshotDelay: 7 days,
          maximumLowerBoundDuration: 3 days,
          priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
            snapshotRatio: uint104(ratio),
            snapshotTimestamp: uint48(block.timestamp - 7 days),
            maxYearlyRatioGrowthPercent: maxYearlyGrowth
          })
        })
      );
  }

  function test_v3AaveOracleSource() public {
    BoundedRatioAdapterMock adapter = _deploy(
      ChainlinkBase.AAVE_SVR_ETH__USD,
      ChainlinkBase.AAVE_SVR_WEETH__EETH_Exchange_Rate,
      8_75
    );

    address[] memory assets = new address[](1);
    assets[0] = AaveV3BaseAssets.weETH_UNDERLYING;
    address[] memory sources = new address[](1);
    sources[0] = address(adapter);
    vm.prank(AaveV3Base.ACL_ADMIN);
    AaveV3Base.ORACLE.setAssetSources(assets, sources);

    uint256 price = AaveV3Base.ORACLE.getAssetPrice(assets[0]);
    assertEq(price, uint256(adapter.latestAnswer()));
    assertApproxEqRel(
      price,
      uint256(IChainlinkAggregator(AaveV3BaseAssets.weETH_ORACLE).latestAnswer()),
      0.001e18
    );
    assertFalse(adapter.isBreached());

    (, , , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(
      updatedAt,
      IChainlinkAggregator(ChainlinkBase.AAVE_SVR_WEETH__EETH_Exchange_Rate).latestTimestamp()
    );

    uint256 ratio = adapter.getBoundedRatio();
    vm.prank(boundsAgent);
    adapter.setLowerBound(uint104((ratio * 99) / 100), uint48(block.timestamp + 1 days));
    (uint256 lastGoodRatio, uint256 lastGoodTimestamp) = adapter.getLastGoodRatio();
    assertEq(lastGoodRatio, ratio);
    assertEq(lastGoodTimestamp, updatedAt);

    vm.mockCallRevert(
      ChainlinkBase.AAVE_SVR_WEETH__EETH_Exchange_Rate,
      IChainlinkAggregator.latestAnswer.selector,
      ''
    );
    assertApproxEqRel(AaveV3Base.ORACLE.getAssetPrice(assets[0]), (price * 99) / 100, 1e10);
    assertTrue(adapter.isBreached());
    assertFalse(adapter.isHeld());

    skip(1 days);
    assertTrue(adapter.isHeld());
    uint256 basePrice = uint256(
      IChainlinkAggregator(ChainlinkBase.AAVE_SVR_ETH__USD).latestAnswer()
    );
    assertEq(AaveV3Base.ORACLE.getAssetPrice(assets[0]), (basePrice * lastGoodRatio) / 1e18);
    (, int256 answer, , uint256 heldUpdatedAt, ) = adapter.latestRoundData();
    assertEq(uint256(answer), AaveV3Base.ORACLE.getAssetPrice(assets[0]));
    assertEq(heldUpdatedAt, lastGoodTimestamp);
  }

  function test_v3NoLastGoodRatio() public {
    BoundedRatioAdapterMock adapter = _deploy(
      ChainlinkBase.AAVE_SVR_ETH__USD,
      ChainlinkBase.AAVE_SVR_WEETH__EETH_Exchange_Rate,
      8_75
    );
    address[] memory assets = new address[](1);
    assets[0] = AaveV3BaseAssets.weETH_UNDERLYING;
    address[] memory sources = new address[](1);
    sources[0] = address(adapter);
    vm.prank(AaveV3Base.ACL_ADMIN);
    AaveV3Base.ORACLE.setAssetSources(assets, sources);

    vm.mockCallRevert(
      ChainlinkBase.AAVE_SVR_WEETH__EETH_Exchange_Rate,
      IChainlinkAggregator.latestAnswer.selector,
      ''
    );
    assertEq(adapter.latestAnswer(), 0);
    vm.expectRevert();
    AaveV3Base.ORACLE.getAssetPrice(assets[0]);
  }

  function test_v4AaveOracleSource() public {
    BoundedRatioAdapterMock adapter = _deploy(address(0), MAG7_SPOKE_AAPLc_PRICE_FEED, 50_00);
    int256 rawPrice = IChainlinkAggregator(MAG7_SPOKE_AAPLc_PRICE_FEED).latestAnswer();

    vm.prank(MAG7_SPOKE);
    MAG7_SPOKE_ORACLE.setReserveSource(AAPLc_RESERVE_ID, address(adapter));
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), uint256(rawPrice));

    vm.prank(boundsAgent);
    adapter.setLowerBound(uint104(uint256(rawPrice) * 9) / 10, uint48(block.timestamp + 3 days));

    vm.mockCall(
      MAG7_SPOKE_AAPLc_PRICE_FEED,
      IChainlinkAggregator.latestAnswer.selector,
      abi.encode(rawPrice / 2)
    );
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), (uint256(rawPrice) * 9) / 10);
    assertTrue(adapter.isFloored());

    vm.mockCall(
      MAG7_SPOKE_AAPLc_PRICE_FEED,
      IChainlinkAggregator.latestAnswer.selector,
      abi.encode(rawPrice * 2)
    );
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), adapter.getMaxRatio());
    assertTrue(adapter.isCapped());

    vm.mockCallRevert(MAG7_SPOKE_AAPLc_PRICE_FEED, IChainlinkAggregator.latestAnswer.selector, '');
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), (uint256(rawPrice) * 9) / 10);

    skip(3 days);
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), uint256(rawPrice));
    assertTrue(adapter.isHeld());
    assertGe(adapter.getLastGoodRatioAge(), 3 days);

    vm.prank(boundsAgent);
    adapter.setLowerBound(uint104(uint256(rawPrice) * 9) / 10, uint48(block.timestamp + 3 days));
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), (uint256(rawPrice) * 9) / 10);
  }

  function test_v4NoLastGoodRatio() public {
    BoundedRatioAdapterMock adapter = _deploy(address(0), MAG7_SPOKE_AAPLc_PRICE_FEED, 50_00);
    int256 rawPrice = IChainlinkAggregator(MAG7_SPOKE_AAPLc_PRICE_FEED).latestAnswer();
    vm.prank(MAG7_SPOKE);
    MAG7_SPOKE_ORACLE.setReserveSource(AAPLc_RESERVE_ID, address(adapter));

    vm.mockCallRevert(MAG7_SPOKE_AAPLc_PRICE_FEED, IChainlinkAggregator.latestAnswer.selector, '');
    vm.expectRevert(abi.encodeWithSelector(IAaveV4Oracle.InvalidPrice.selector, AAPLc_RESERVE_ID));
    MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID);

    vm.clearMockedCalls();
    adapter.recordRatio();
    vm.mockCallRevert(MAG7_SPOKE_AAPLc_PRICE_FEED, IChainlinkAggregator.latestAnswer.selector, '');
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(AAPLc_RESERVE_ID), uint256(rawPrice));
  }
}
