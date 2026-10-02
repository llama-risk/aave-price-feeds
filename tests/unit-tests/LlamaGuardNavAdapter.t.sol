// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from 'forge-std/Test.sol';

import {IBoundedRatioAdapter, IPriceCapAdapter, IACLManager} from '../../src/interfaces/IBoundedRatioAdapter.sol';
import {ILlamaGuardOracle} from '../../src/interfaces/ILlamaGuardOracle.sol';
import {LlamaGuardNavAdapter} from '../../src/contracts/LlamaGuardNavAdapter.sol';

import {LlamaGuardOracleMock} from './mocks/LlamaGuardOracleMock.sol';
import {ACLManagerMock} from './mocks/ACLManagerMock.sol';

contract LlamaGuardNavAdapterTest is Test {
  LlamaGuardOracleMock public navOracle;
  ACLManagerMock public aclManager;

  LlamaGuardNavAdapter public adapter;

  address public riskAdmin = address(0xDead);
  address public poolAdmin = address(0xBeef);

  int256 public constant NAV = 11.22883e6;
  uint104 public constant SNAPSHOT_NAV = 11.2e6;
  uint16 public constant MAX_YEARLY_GROWTH = 5_00;
  uint48 public constant MAX_LOWER_BOUND_DURATION = 3 days;
  uint48 public constant MAX_NAV_AGE = 4 days;

  function setUp() public {
    skip(365 days);

    navOracle = new LlamaGuardOracleMock();
    navOracle.setAnswer(NAV);
    aclManager = new ACLManagerMock(poolAdmin, riskAdmin);

    adapter = new LlamaGuardNavAdapter(_params(address(navOracle), SNAPSHOT_NAV));
    skip(1 hours);
  }

  function _params(
    address oracle,
    uint104 snapshotRatio
  ) internal view returns (LlamaGuardNavAdapter.LlamaGuardNavAdapterParams memory) {
    return _params(oracle, snapshotRatio, MAX_NAV_AGE);
  }

  function _params(
    address oracle,
    uint104 snapshotRatio,
    uint48 maxNavAge
  ) internal view returns (LlamaGuardNavAdapter.LlamaGuardNavAdapterParams memory) {
    return
      LlamaGuardNavAdapter.LlamaGuardNavAdapterParams({
        aclManager: IACLManager(address(aclManager)),
        navOracle: oracle,
        pairDescription: 'USTB / USD',
        minimumSnapshotDelay: 7 days,
        maximumLowerBoundDuration: MAX_LOWER_BOUND_DURATION,
        maxNavAge: maxNavAge,
        priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
          snapshotRatio: snapshotRatio,
          snapshotTimestamp: uint48(block.timestamp - 30 days),
          maxYearlyRatioGrowthPercent: MAX_YEARLY_GROWTH
        })
      });
  }

  function _setLowerBound(uint256 lowerBound) internal {
    vm.prank(riskAdmin);
    adapter.setLowerBound(uint104(lowerBound), uint48(block.timestamp + 1 days));
  }

  function test_setup() public view {
    assertEq(adapter.RATIO_PROVIDER(), address(navOracle));
    assertEq(address(adapter.BASE_TO_USD_AGGREGATOR()), address(0));
    assertEq(address(adapter.ACL_MANAGER()), address(aclManager));
    assertEq(adapter.RATIO_DECIMALS(), 6);
    assertEq(adapter.MAX_NAV_AGE(), MAX_NAV_AGE);
    assertEq(adapter.decimals(), 8);
    assertEq(adapter.description(), 'USTB / USD');
    assertEq(adapter.getRatio(), NAV);
    assertEq(adapter.getBoundedRatio(), uint256(NAV));
    assertEq(adapter.latestAnswer(), NAV * 100);
    assertFalse(adapter.isBreached());
    assertFalse(adapter.isHeld());
    (uint256 lastGood, uint256 lastGoodAt) = adapter.getLastGoodRatio();
    assertEq(lastGood, 0);
    assertEq(lastGoodAt, 0);
    assertEq(adapter.getLastGoodRatioAge(), type(uint256).max);

    (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = adapter.latestRoundData();
    assertEq(roundId, 0);
    assertEq(answer, NAV * 100);
    assertEq(startedAt, block.timestamp - 1 hours);
    assertEq(updatedAt, block.timestamp - 1 hours);
    assertEq(answeredInRound, 0);
  }

  function test_constructorReverts() public {
    vm.expectRevert(IBoundedRatioAdapter.RatioProviderIsZeroAddress.selector);
    new LlamaGuardNavAdapter(_params(address(0), SNAPSHOT_NAV));

    navOracle.setDecimals(5);
    vm.expectRevert(IPriceCapAdapter.WrongRatioDecimals.selector);
    new LlamaGuardNavAdapter(_params(address(navOracle), SNAPSHOT_NAV));

    vm.expectRevert();
    new LlamaGuardNavAdapter(_params(address(aclManager), SNAPSHOT_NAV));

    navOracle.setDecimals(6);
    vm.expectRevert(LlamaGuardNavAdapter.InvalidMaxNavAge.selector);
    new LlamaGuardNavAdapter(_params(address(navOracle), SNAPSHOT_NAV, 0));
  }

  function test_decimalsScaling() public {
    LlamaGuardOracleMock oracle18 = new LlamaGuardOracleMock();
    oracle18.setDecimals(18);
    oracle18.setAnswer(11.22883e18);
    LlamaGuardNavAdapter adapter18 = new LlamaGuardNavAdapter(_params(address(oracle18), 11.2e18));
    assertEq(adapter18.latestAnswer(), 11.22883e8);

    LlamaGuardOracleMock oracle8 = new LlamaGuardOracleMock();
    oracle8.setDecimals(8);
    oracle8.setAnswer(11.22883e8);
    assertEq(
      new LlamaGuardNavAdapter(_params(address(oracle8), 11.2e8)).latestAnswer(),
      11.22883e8
    );
  }

  function test_navTracksOracleBetweenBoundUpdates() public {
    _setLowerBound(11.2e6);

    navOracle.setAnswer(11.24e6);
    assertEq(adapter.latestAnswer(), 11.24e8);
    (, , , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, block.timestamp);
    assertFalse(adapter.isBreached());
  }

  function test_navDropFloored() public {
    _setLowerBound(11.2e6);

    navOracle.setAnswer(10e6);
    assertEq(adapter.latestAnswer(), 11.2e8);
    assertTrue(adapter.isFloored());
    assertTrue(adapter.isBreached());

    skip(1 days);
    assertEq(adapter.latestAnswer(), 10e8);
    assertFalse(adapter.isBreached());
  }

  function test_navJumpCapped() public {
    navOracle.setAnswer(13e6);
    uint256 maxRatio = adapter.getMaxRatio();
    assertGt(maxRatio, SNAPSHOT_NAV);
    assertLt(maxRatio, 11.25e6);
    assertEq(uint256(adapter.latestAnswer()), maxRatio * 100);
    assertTrue(adapter.isCapped());
    assertTrue(adapter.isBreached());

    skip(365 days);
    assertApproxEqAbs(adapter.getMaxRatio(), 11_806_091, 20);
  }

  function test_emptyOracle() public {
    LlamaGuardOracleMock empty = new LlamaGuardOracleMock();
    LlamaGuardNavAdapter emptyAdapter = new LlamaGuardNavAdapter(
      _params(address(empty), SNAPSHOT_NAV)
    );
    assertEq(emptyAdapter.latestAnswer(), 0);
    assertTrue(emptyAdapter.isBreached());
    (, int256 answer, , uint256 updatedAt, ) = emptyAdapter.latestRoundData();
    assertEq(answer, 0);
    assertEq(updatedAt, 0);
  }

  function test_nonPositiveNavUsesLowerBoundThenLastGood() public {
    uint256 navUpdatedAt = block.timestamp - 1 hours;
    _setLowerBound(11.2e6);

    navOracle.setAnswer(0);
    assertEq(adapter.latestAnswer(), 11.2e8);
    navOracle.setAnswer(-1);
    assertEq(adapter.getRatio(), 0);
    assertTrue(adapter.isBreached());
    (, int256 answer, , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, 11.2e8);
    assertEq(updatedAt, 0);

    skip(1 days);
    (, answer, , updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, NAV * 100);
    assertEq(updatedAt, navUpdatedAt);
    assertTrue(adapter.isHeld());
    assertTrue(adapter.isBreached());
  }

  function test_oracleRevertUsesLowerBoundThenLastGood() public {
    _setLowerBound(11.2e6);

    vm.mockCallRevert(address(navOracle), ILlamaGuardOracle.latestRoundData.selector, '');
    assertEq(adapter.latestAnswer(), 11.2e8);
    assertTrue(adapter.isBreached());
    (, int256 answer, , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, 11.2e8);
    assertEq(updatedAt, 0);

    skip(1 days);
    assertEq(adapter.latestAnswer(), NAV * 100);
    assertTrue(adapter.isHeld());

    vm.prank(riskAdmin);
    adapter.setLowerBound(11.2e6, uint48(block.timestamp + 1 days));
    assertEq(adapter.latestAnswer(), 11.2e8);
    assertFalse(adapter.isHeld());
  }

  function test_malformedOracleDataUsesLowerBound() public {
    _setLowerBound(11.2e6);

    vm.mockCall(
      address(navOracle),
      ILlamaGuardOracle.latestRoundData.selector,
      abi.encode(uint256(1), NAV)
    );
    assertEq(adapter.latestAnswer(), 11.2e8);
    (, , , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, 0);

    vm.mockCall(
      address(navOracle),
      ILlamaGuardOracle.latestRoundData.selector,
      abi.encode(type(uint256).max, NAV, 0, block.timestamp, type(uint256).max)
    );
    assertEq(adapter.latestAnswer(), 11.2e8);
    (, , , updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, 0);
  }

  function test_staleNavUsesLowerBoundThenLastGood() public {
    navOracle.setAnswer(NAV);
    uint256 navUpdatedAt = block.timestamp;
    skip(MAX_NAV_AGE - 1 days);
    vm.prank(riskAdmin);
    adapter.setLowerBound(11.2e6, uint48(block.timestamp + MAX_LOWER_BOUND_DURATION));
    skip(1 days);
    assertEq(adapter.latestAnswer(), NAV * 100);
    assertFalse(adapter.isBreached());

    skip(1);
    assertEq(adapter.getRatio(), 0);
    assertEq(adapter.latestAnswer(), 11.2e8);
    assertTrue(adapter.isBreached());
    (, , , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, 0);

    vm.startPrank(riskAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IBoundedRatioAdapter.InvalidLowerBound.selector, 11.21e6)
    );
    adapter.setLowerBound(11.21e6, uint48(block.timestamp + 1 days));
    adapter.setLowerBound(11.2e6, uint48(block.timestamp + 1 days));
    vm.stopPrank();

    skip(1 days);
    (, int256 answer, , uint256 heldUpdatedAt, ) = adapter.latestRoundData();
    assertEq(answer, NAV * 100);
    assertEq(heldUpdatedAt, navUpdatedAt);
    assertGt(block.timestamp - heldUpdatedAt, MAX_NAV_AGE);
    assertTrue(adapter.isHeld());

    navOracle.setAnswer(11.23e6);
    assertEq(adapter.latestAnswer(), 11.23e8);
    assertFalse(adapter.isHeld());
  }

  function test_recordRatio() public {
    uint256 navUpdatedAt = block.timestamp - 1 hours;
    vm.expectEmit(address(adapter));
    emit IBoundedRatioAdapter.LastGoodRatioRecorded(uint256(NAV), navUpdatedAt);
    assertEq(adapter.recordRatio(), uint256(NAV));
    (uint256 lastGood, uint256 lastGoodAt) = adapter.getLastGoodRatio();
    assertEq(lastGood, uint256(NAV));
    assertEq(lastGoodAt, navUpdatedAt);
    assertEq(adapter.getLastGoodRatioAge(), 1 hours);

    skip(MAX_NAV_AGE);
    vm.expectRevert(IBoundedRatioAdapter.NoValidRatio.selector);
    adapter.recordRatio();
    assertEq(adapter.latestAnswer(), NAV * 100);
    (, , , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(updatedAt, navUpdatedAt);

    navOracle.setAnswer(11.23e6);
    assertEq(adapter.recordRatio(), 11.23e6);
    assertEq(adapter.getLastGoodRatioAge(), 0);
  }

  function test_futureNavRoundIgnored() public {
    vm.mockCall(
      address(navOracle),
      ILlamaGuardOracle.latestRoundData.selector,
      abi.encode(uint80(1), NAV, block.timestamp + 1, block.timestamp + 1, uint80(1))
    );
    assertEq(adapter.getRatio(), 0);
    assertEq(adapter.latestAnswer(), 0);
    assertTrue(adapter.isBreached());
    vm.expectRevert(IBoundedRatioAdapter.NoValidRatio.selector);
    adapter.recordRatio();
  }

  function testFuzz_answerWithinBounds(int256 nav, uint256 lowerBound, uint256 elapsed) public {
    elapsed = bound(elapsed, 0, 2 * MAX_LOWER_BOUND_DURATION);
    lowerBound = bound(lowerBound, 1, uint256(NAV));
    _setLowerBound(lowerBound);
    navOracle.setAnswer(nav);
    skip(elapsed);

    uint256 lowerNow = adapter.getActiveLowerBound();
    uint256 upperNow = adapter.getMaxRatio();
    uint256 raw = nav > 0 && elapsed <= MAX_NAV_AGE ? uint256(nav) : 0;
    uint256 expected = raw < lowerNow ? lowerNow : raw;
    // setLowerBound recorded NAV as the last good ratio
    if (expected == 0) expected = uint256(NAV);
    if (expected > upperNow) expected = upperNow;

    assertEq(uint256(adapter.latestAnswer()), expected * 100);
    assertEq(adapter.isHeld(), raw == 0 && lowerNow == 0);
    assertEq(adapter.isBreached(), raw == 0 || raw < lowerNow || raw > upperNow);
  }
}
