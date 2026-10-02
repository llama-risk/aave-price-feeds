// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from 'forge-std/Test.sol';
import {AaveV3EthereumHorizon, AaveV3EthereumHorizonAssets} from 'aave-address-book/AaveV3EthereumHorizon.sol';

import {IPriceCapAdapter, IChainlinkAggregator} from '../src/interfaces/IPriceCapAdapter.sol';
import {IBoundedRatioAdapter} from '../src/interfaces/IBoundedRatioAdapter.sol';
import {ILlamaGuardOracle} from '../src/interfaces/ILlamaGuardOracle.sol';
import {LlamaGuardNavAdapter} from '../src/contracts/LlamaGuardNavAdapter.sol';

interface IAaveV4Oracle {
  function setReserveSource(uint256 reserveId, address source) external;

  function getReservePrice(uint256 reserveId) external view returns (uint256);

  error InvalidPrice(uint256 reserveId);
}

contract LlamaGuardNavAdapterForkTest is Test {
  ILlamaGuardOracle public constant USTB_NAV_ORACLE =
    ILlamaGuardOracle(0xc11B9FbFF1739dba70D1418BC8E6828cE66f61A2);
  IAaveV4Oracle public constant MAIN_SPOKE_ORACLE =
    IAaveV4Oracle(0x99B2B6CEa9C3D2fd8F4d90f86741C44B212a6127);
  address public constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;

  uint16 public constant MAX_YEARLY_GROWTH = 5_00;
  uint48 public constant MAX_LOWER_BOUND_DURATION = 5 days;
  uint48 public constant MAX_NAV_AGE = 4 days;
  uint256 public constant LOWER_BOUND_DISCOUNT_BPS = 15;

  address public boundsAgent = makeAddr('boundsAgent');

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('mainnet'), 26103683);

    vm.prank(AaveV3EthereumHorizon.ACL_ADMIN);
    AaveV3EthereumHorizon.ACL_MANAGER.addRiskAdmin(boundsAgent);
  }

  function _deploy(
    uint104 snapshotRatio,
    uint48 snapshotTimestamp,
    uint48 minimumSnapshotDelay
  ) internal returns (LlamaGuardNavAdapter) {
    return
      new LlamaGuardNavAdapter(
        LlamaGuardNavAdapter.LlamaGuardNavAdapterParams({
          aclManager: AaveV3EthereumHorizon.ACL_MANAGER,
          navOracle: address(USTB_NAV_ORACLE),
          pairDescription: 'USTB / USD',
          minimumSnapshotDelay: minimumSnapshotDelay,
          maximumLowerBoundDuration: MAX_LOWER_BOUND_DURATION,
          maxNavAge: MAX_NAV_AGE,
          priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
            snapshotRatio: snapshotRatio,
            snapshotTimestamp: snapshotTimestamp,
            maxYearlyRatioGrowthPercent: MAX_YEARLY_GROWTH
          })
        })
      );
  }

  function _deployFromRecentRound() internal returns (LlamaGuardNavAdapter) {
    (uint80 latestRound, , , , ) = USTB_NAV_ORACLE.latestRoundData();
    uint80 roundId = latestRound;
    uint256 updatedAt;
    int256 answer;
    do {
      (, answer, , updatedAt, ) = USTB_NAV_ORACLE.getRoundData(--roundId);
    } while (updatedAt > block.timestamp - 7 days);
    return _deploy(uint104(uint256(answer)), uint48(updatedAt), 7 days);
  }

  function _setLowerBound(LlamaGuardNavAdapter adapter, uint256 nav) internal {
    vm.prank(boundsAgent);
    adapter.setLowerBound(
      uint104((nav * (1e4 - LOWER_BOUND_DISCOUNT_BPS)) / 1e4),
      uint48(block.timestamp + MAX_LOWER_BOUND_DURATION)
    );
  }

  function test_horizonSource() public {
    LlamaGuardNavAdapter adapter = _deployFromRecentRound();
    (, int256 nav, , uint256 navUpdatedAt, ) = USTB_NAV_ORACLE.latestRoundData();

    assertEq(adapter.decimals(), 8);
    assertEq(adapter.latestAnswer(), nav * 100);
    assertFalse(adapter.isBreached());
    (, , , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, navUpdatedAt);

    address[] memory assets = new address[](1);
    assets[0] = AaveV3EthereumHorizonAssets.USTB_UNDERLYING;
    address[] memory sources = new address[](1);
    sources[0] = address(adapter);
    vm.prank(AaveV3EthereumHorizon.ACL_ADMIN);
    AaveV3EthereumHorizon.ORACLE.setAssetSources(assets, sources);

    uint256 price = AaveV3EthereumHorizon.ORACLE.getAssetPrice(assets[0]);
    assertEq(price, uint256(nav) * 100);
    assertApproxEqRel(
      price,
      uint256(IChainlinkAggregator(AaveV3EthereumHorizonAssets.USTB_ORACLE).latestAnswer()),
      0.005e18
    );

    _setLowerBound(adapter, uint256(nav));
    vm.mockCallRevert(address(USTB_NAV_ORACLE), ILlamaGuardOracle.latestRoundData.selector, '');
    assertEq(
      AaveV3EthereumHorizon.ORACLE.getAssetPrice(assets[0]),
      ((uint256(nav) * (1e4 - LOWER_BOUND_DISCOUNT_BPS)) / 1e4) * 100
    );
    assertTrue(adapter.isBreached());

    skip(MAX_LOWER_BOUND_DURATION);
    assertEq(AaveV3EthereumHorizon.ORACLE.getAssetPrice(assets[0]), uint256(nav) * 100);
    assertTrue(adapter.isHeld());
    (, , , updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, navUpdatedAt);

    vm.clearMockedCalls();
    sources[0] = address(_deployFromRecentRound());
    vm.mockCallRevert(address(USTB_NAV_ORACLE), ILlamaGuardOracle.latestRoundData.selector, '');
    vm.prank(AaveV3EthereumHorizon.ACL_ADMIN);
    AaveV3EthereumHorizon.ORACLE.setAssetSources(assets, sources);
    vm.expectRevert();
    AaveV3EthereumHorizon.ORACLE.getAssetPrice(assets[0]);
  }

  function test_staleNav() public {
    LlamaGuardNavAdapter adapter = _deployFromRecentRound();
    (, int256 nav, , uint256 navUpdatedAt, ) = USTB_NAV_ORACLE.latestRoundData();
    _setLowerBound(adapter, uint256(nav));

    vm.warp(navUpdatedAt + MAX_NAV_AGE + 1);
    assertEq(adapter.getRatio(), 0);
    assertTrue(adapter.isBreached());
    (, int256 answer, , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, int256(adapter.getActiveLowerBound()) * 100);
    assertEq(updatedAt, 0);
    vm.expectRevert(IBoundedRatioAdapter.NoValidRatio.selector);
    adapter.recordRatio();

    skip(MAX_LOWER_BOUND_DURATION);
    (, answer, , updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, nav * 100);
    assertEq(updatedAt, navUpdatedAt);
    assertTrue(adapter.isHeld());
  }

  function test_v4PriceFeed() public {
    LlamaGuardNavAdapter adapter = _deployFromRecentRound();
    (, int256 nav, , , ) = USTB_NAV_ORACLE.latestRoundData();

    vm.prank(MAIN_SPOKE);
    MAIN_SPOKE_ORACLE.setReserveSource(0, address(adapter));
    assertEq(MAIN_SPOKE_ORACLE.getReservePrice(0), uint256(nav) * 100);

    _setLowerBound(adapter, uint256(nav));
    vm.mockCall(
      address(USTB_NAV_ORACLE),
      ILlamaGuardOracle.latestRoundData.selector,
      abi.encode(uint80(0), nav / 2, 0, block.timestamp, uint80(0))
    );
    assertEq(
      MAIN_SPOKE_ORACLE.getReservePrice(0),
      ((uint256(nav) * (1e4 - LOWER_BOUND_DISCOUNT_BPS)) / 1e4) * 100
    );
    assertTrue(adapter.isFloored());

    skip(MAX_LOWER_BOUND_DURATION);
    vm.mockCall(
      address(USTB_NAV_ORACLE),
      ILlamaGuardOracle.latestRoundData.selector,
      abi.encode(uint80(0), nav / 2, 0, block.timestamp, uint80(0))
    );
    assertEq(MAIN_SPOKE_ORACLE.getReservePrice(0), (uint256(nav) / 2) * 100);
    assertEq(adapter.recordRatio(), uint256(nav) / 2);

    vm.mockCallRevert(address(USTB_NAV_ORACLE), ILlamaGuardOracle.latestRoundData.selector, '');
    assertEq(MAIN_SPOKE_ORACLE.getReservePrice(0), (uint256(nav) / 2) * 100);
    assertTrue(adapter.isHeld());

    // live NAV is now stale and a new adapter has no last good ratio
    vm.clearMockedCalls();
    LlamaGuardNavAdapter unrecorded = _deployFromRecentRound();
    assertEq(unrecorded.latestAnswer(), 0);
    vm.prank(MAIN_SPOKE);
    vm.expectRevert(abi.encodeWithSelector(IAaveV4Oracle.InvalidPrice.selector, 0));
    MAIN_SPOKE_ORACLE.setReserveSource(0, address(unrecorded));
  }

  function test_replayBoundedNavHistory() public {
    (uint80 latestRound, , , , ) = USTB_NAV_ORACLE.latestRoundData();
    (, int256 firstNav, , uint256 firstUpdatedAt, ) = USTB_NAV_ORACLE.getRoundData(1);

    vm.warp(firstUpdatedAt);
    LlamaGuardNavAdapter adapter = _deploy(uint104(uint256(firstNav)), uint48(firstUpdatedAt), 0);

    uint256 breaches;
    for (uint80 roundId = 1; roundId <= latestRound; roundId++) {
      (
        uint80 id,
        int256 nav,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
      ) = USTB_NAV_ORACLE.getRoundData(roundId);
      vm.warp(updatedAt);
      vm.mockCall(
        address(USTB_NAV_ORACLE),
        ILlamaGuardOracle.latestRoundData.selector,
        abi.encode(id, nav, startedAt, updatedAt, answeredInRound)
      );

      if (adapter.isBreached()) {
        breaches++;
      } else {
        assertEq(adapter.latestAnswer(), nav * 100);
      }
      _setLowerBound(adapter, uint256(nav));
    }
    assertEq(breaches, 0);
    (, int256 latestNav, , uint256 latestUpdatedAt, ) = USTB_NAV_ORACLE.getRoundData(latestRound);
    (uint256 lastGood, uint256 lastGoodAt) = adapter.getLastGoodRatio();
    assertEq(lastGood, uint256(latestNav));
    assertEq(lastGoodAt, latestUpdatedAt);
  }
}
