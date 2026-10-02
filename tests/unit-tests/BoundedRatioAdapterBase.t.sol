// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from 'forge-std/Test.sol';

import {IBoundedRatioAdapter, IPriceCapAdapter, ICLSynchronicityPriceAdapter, IACLManager, IChainlinkAggregator} from '../../src/interfaces/IBoundedRatioAdapter.sol';

import {BoundedRatioAdapterMock} from './mocks/BoundedRatioAdapterMock.sol';
import {ChainlinkAggregatorMock} from './mocks/ChainlinkAggregatorMock.sol';
import {ACLManagerMock} from './mocks/ACLManagerMock.sol';

contract BoundedRatioAdapterBaseTest is Test {
  ChainlinkAggregatorMock public baseFeed;
  ChainlinkAggregatorMock public ratioFeed;
  ACLManagerMock public aclManager;

  BoundedRatioAdapterMock public adapter;

  address public riskAdmin = address(0xDead);
  address public poolAdmin = address(0xBeef);

  uint104 public constant SNAPSHOT_RATIO = 1e18;
  uint16 public constant MAX_YEARLY_GROWTH = 10_00;
  uint48 public constant MAX_LOWER_BOUND_DURATION = 7 days;

  function setUp() public {
    skip(365 days + 1);

    baseFeed = new ChainlinkAggregatorMock(2_000e8);
    ratioFeed = new ChainlinkAggregatorMock(1e18);
    ratioFeed.setDecimals(18);
    aclManager = new ACLManagerMock(poolAdmin, riskAdmin);

    adapter = new BoundedRatioAdapterMock(_params(address(baseFeed), 18));
  }

  function _params(
    address base,
    uint8 ratioDecimals
  ) internal view returns (IBoundedRatioAdapter.BoundedRatioAdapterParams memory) {
    return
      IBoundedRatioAdapter.BoundedRatioAdapterParams({
        aclManager: IACLManager(address(aclManager)),
        baseAggregatorAddress: base,
        ratioProviderAddress: address(ratioFeed),
        pairDescription: 'description',
        ratioDecimals: ratioDecimals,
        minimumSnapshotDelay: 0,
        maximumLowerBoundDuration: MAX_LOWER_BOUND_DURATION,
        priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
          snapshotRatio: SNAPSHOT_RATIO,
          snapshotTimestamp: uint48(block.timestamp),
          maxYearlyRatioGrowthPercent: MAX_YEARLY_GROWTH
        })
      });
  }

  function _setLowerBound(uint104 lowerBound) internal {
    vm.prank(riskAdmin);
    adapter.setLowerBound(lowerBound, uint48(block.timestamp + 1 days));
  }

  function test_setup() public view {
    assertEq(address(adapter.BASE_TO_USD_AGGREGATOR()), address(baseFeed));
    assertEq(address(adapter.ACL_MANAGER()), address(aclManager));
    assertEq(adapter.RATIO_PROVIDER(), address(ratioFeed));
    assertEq(adapter.DECIMALS(), 8);
    assertEq(adapter.decimals(), 8);
    assertEq(adapter.RATIO_DECIMALS(), 18);
    assertEq(adapter.MINIMUM_SNAPSHOT_DELAY(), 0);
    assertEq(adapter.MAXIMUM_SNAPSHOT_TERM(), 180 days);
    assertEq(adapter.MAXIMUM_LOWER_BOUND_DURATION(), MAX_LOWER_BOUND_DURATION);
    assertEq(adapter.description(), 'description');
    assertEq(adapter.getSnapshotRatio(), SNAPSHOT_RATIO);
    assertEq(adapter.getSnapshotTimestamp(), block.timestamp);
    assertEq(adapter.getMaxYearlyGrowthRatePercent(), MAX_YEARLY_GROWTH);
    assertEq(adapter.getMaxRatioGrowthPerSecondScaled(), 3170979198376458);
    assertEq(adapter.getMaxRatioGrowthPerSecond(), 3170979198);
    assertEq(adapter.getMaxRatio(), SNAPSHOT_RATIO);
    assertEq(adapter.getRatio(), 1e18);
    assertEq(adapter.getBoundedRatio(), 1e18);
    assertEq(adapter.getActiveLowerBound(), 0);
    assertEq(adapter.latestAnswer(), 2_000e8);
    assertFalse(adapter.isCapped());
    assertFalse(adapter.isFloored());
    assertFalse(adapter.isBreached());
  }

  function test_constructorReverts() public {
    IBoundedRatioAdapter.BoundedRatioAdapterParams memory params = _params(address(baseFeed), 18);
    params.aclManager = IACLManager(address(0));
    vm.expectRevert(IPriceCapAdapter.ACLManagerIsZeroAddress.selector);
    new BoundedRatioAdapterMock(params);

    params = _params(address(baseFeed), 18);
    params.ratioProviderAddress = address(0);
    vm.expectRevert(IBoundedRatioAdapter.RatioProviderIsZeroAddress.selector);
    new BoundedRatioAdapterMock(params);

    vm.expectRevert(IPriceCapAdapter.WrongRatioDecimals.selector);
    new BoundedRatioAdapterMock(_params(address(baseFeed), 5));

    vm.expectRevert(IPriceCapAdapter.WrongRatioDecimals.selector);
    new BoundedRatioAdapterMock(_params(address(baseFeed), 25));

    params = _params(address(baseFeed), 18);
    params.maximumLowerBoundDuration = 0;
    vm.expectRevert(IBoundedRatioAdapter.InvalidLowerBoundDuration.selector);
    new BoundedRatioAdapterMock(params);

    params.maximumLowerBoundDuration = 180 days + 1;
    vm.expectRevert(IBoundedRatioAdapter.InvalidLowerBoundDuration.selector);
    new BoundedRatioAdapterMock(params);

    ChainlinkAggregatorMock wideFeed = new ChainlinkAggregatorMock(1e8);
    wideFeed.setDecimals(25);
    vm.expectRevert(ICLSynchronicityPriceAdapter.DecimalsAboveLimit.selector);
    new BoundedRatioAdapterMock(_params(address(wideFeed), 18));

    params = _params(address(baseFeed), 18);
    params.priceCapParams.snapshotRatio = 0;
    vm.expectRevert(IPriceCapAdapter.SnapshotRatioIsZero.selector);
    new BoundedRatioAdapterMock(params);

    params = _params(address(baseFeed), 18);
    params.priceCapParams.snapshotTimestamp = uint48(block.timestamp + 1);
    vm.expectRevert(
      abi.encodeWithSelector(IPriceCapAdapter.InvalidRatioTimestamp.selector, block.timestamp + 1)
    );
    new BoundedRatioAdapterMock(params);
  }

  function test_decimalsScaling() public {
    ChainlinkAggregatorMock feed18 = new ChainlinkAggregatorMock(2_000e18);
    feed18.setDecimals(18);
    assertEq(new BoundedRatioAdapterMock(_params(address(feed18), 18)).latestAnswer(), 2_000e8);

    ChainlinkAggregatorMock feed6 = new ChainlinkAggregatorMock(2_000e6);
    feed6.setDecimals(6);
    assertEq(new BoundedRatioAdapterMock(_params(address(feed6), 18)).latestAnswer(), 2_000e8);

    assertEq(new BoundedRatioAdapterMock(_params(address(0), 18)).latestAnswer(), 1e8);

    ratioFeed.setLatestAnswer(1.05e6);
    IBoundedRatioAdapter.BoundedRatioAdapterParams memory params = _params(address(0), 6);
    params.priceCapParams.snapshotRatio = 1.1e6;
    assertEq(new BoundedRatioAdapterMock(params).latestAnswer(), 1.05e8);

    ratioFeed.setLatestAnswer(1.05e8);
    params = _params(address(feed6), 8);
    params.priceCapParams.snapshotRatio = 1.1e8;
    assertEq(new BoundedRatioAdapterMock(params).latestAnswer(), 2_100e8);
  }

  function test_upperBoundGrowth() public {
    ratioFeed.setLatestAnswer(1.2e18);
    assertEq(adapter.latestAnswer(), 2_000e8);
    assertTrue(adapter.isCapped());
    assertTrue(adapter.isBreached());

    skip(365 days);
    assertApproxEqAbs(adapter.getMaxRatio(), 1.1e18, 1e7);
    assertApproxEqAbs(adapter.latestAnswer(), 2_200e8, 1);
    assertTrue(adapter.isCapped());

    skip(365 days);
    ratioFeed.setLatestAnswer(1.15e18);
    assertEq(adapter.getBoundedRatio(), 1.15e18);
    assertFalse(adapter.isCapped());
    assertFalse(adapter.isBreached());
  }

  function test_setCapParameters() public {
    skip(1 days);
    vm.expectRevert(IPriceCapAdapter.CallerIsNotRiskOrPoolAdmin.selector);
    adapter.setCapParameters(
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: 1.01e18,
        snapshotTimestamp: uint48(block.timestamp),
        maxYearlyRatioGrowthPercent: 5_00
      })
    );

    vm.expectRevert(
      abi.encodeWithSelector(
        IPriceCapAdapter.InvalidRatioTimestamp.selector,
        block.timestamp - 1 days
      )
    );
    vm.prank(riskAdmin);
    adapter.setCapParameters(
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: 1.01e18,
        snapshotTimestamp: uint48(block.timestamp - 1 days),
        maxYearlyRatioGrowthPercent: 5_00
      })
    );

    vm.expectEmit(address(adapter));
    emit IPriceCapAdapter.CapParametersUpdated(1.01e18, block.timestamp, 1601344495, 5_00);
    vm.prank(poolAdmin);
    adapter.setCapParameters(
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: 1.01e18,
        snapshotTimestamp: uint48(block.timestamp),
        maxYearlyRatioGrowthPercent: 5_00
      })
    );
    assertEq(adapter.getSnapshotRatio(), 1.01e18);
    assertEq(adapter.getMaxRatio(), 1.01e18);
  }

  function test_setLowerBound() public {
    vm.expectRevert(IPriceCapAdapter.CallerIsNotRiskOrPoolAdmin.selector);
    adapter.setLowerBound(0.95e18, uint48(block.timestamp + 1 days));

    vm.expectEmit(address(adapter));
    emit IBoundedRatioAdapter.LowerBoundUpdated(0.95e18, block.timestamp + 1 days);
    vm.prank(riskAdmin);
    adapter.setLowerBound(0.95e18, uint48(block.timestamp + 1 days));

    (uint256 lowerBound, uint256 expiration) = adapter.getLowerBound();
    assertEq(lowerBound, 0.95e18);
    assertEq(expiration, block.timestamp + 1 days);
    assertEq(adapter.getActiveLowerBound(), 0.95e18);

    vm.prank(poolAdmin);
    adapter.setLowerBound(1e18, uint48(block.timestamp + MAX_LOWER_BOUND_DURATION));
    assertEq(adapter.getActiveLowerBound(), 1e18);
  }

  function test_setLowerBoundInvalidExpiration() public {
    vm.startPrank(riskAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IBoundedRatioAdapter.InvalidLowerBoundExpiration.selector,
        block.timestamp
      )
    );
    adapter.setLowerBound(0.95e18, uint48(block.timestamp));

    uint48 tooLate = uint48(block.timestamp + MAX_LOWER_BOUND_DURATION + 1);
    vm.expectRevert(
      abi.encodeWithSelector(IBoundedRatioAdapter.InvalidLowerBoundExpiration.selector, tooLate)
    );
    adapter.setLowerBound(0.95e18, tooLate);
    vm.stopPrank();
  }

  function test_setLowerBoundCannotRaisePrice() public {
    vm.expectRevert(
      abi.encodeWithSelector(IBoundedRatioAdapter.InvalidLowerBound.selector, 1e18 + 1)
    );
    vm.prank(riskAdmin);
    adapter.setLowerBound(1e18 + 1, uint48(block.timestamp + 1 days));

    ratioFeed.setLatestAnswer(1.2e18);
    vm.expectRevert(
      abi.encodeWithSelector(IBoundedRatioAdapter.InvalidLowerBound.selector, 1e18 + 1)
    );
    vm.prank(riskAdmin);
    adapter.setLowerBound(1e18 + 1, uint48(block.timestamp + 1 days));
  }

  function test_lowerBoundHoldsUntilExpiration() public {
    _setLowerBound(0.95e18);

    ratioFeed.setLatestAnswer(0.5e18);
    assertEq(adapter.getBoundedRatio(), 0.95e18);
    assertEq(adapter.latestAnswer(), 1_900e8);
    assertTrue(adapter.isFloored());
    assertTrue(adapter.isBreached());
    assertFalse(adapter.isCapped());

    skip(1 days - 1);
    assertEq(adapter.latestAnswer(), 1_900e8);

    skip(1);
    assertEq(adapter.getActiveLowerBound(), 0);
    assertEq(adapter.latestAnswer(), 1_000e8);
    assertFalse(adapter.isFloored());
    assertFalse(adapter.isBreached());
  }

  function test_lowerBoundRenewalDuringBreach() public {
    _setLowerBound(0.95e18);
    ratioFeed.setLatestAnswer(0.5e18);

    vm.expectRevert(
      abi.encodeWithSelector(IBoundedRatioAdapter.InvalidLowerBound.selector, 0.95e18 + 1)
    );
    vm.prank(riskAdmin);
    adapter.setLowerBound(0.95e18 + 1, uint48(block.timestamp + 1 days));

    skip(12 hours);
    _setLowerBound(0.95e18);
    skip(1 days - 1);
    assertEq(adapter.latestAnswer(), 1_900e8);

    _setLowerBound(0);
    assertEq(adapter.latestAnswer(), 1_000e8);
  }

  function test_upperBoundWinsOverLowerBound() public {
    skip(365 days);
    ratioFeed.setLatestAnswer(1.08e18);
    _setLowerBound(1.08e18);

    vm.prank(riskAdmin);
    adapter.setCapParameters(
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: 1.02e18,
        snapshotTimestamp: uint48(block.timestamp),
        maxYearlyRatioGrowthPercent: 0
      })
    );

    assertEq(adapter.getBoundedRatio(), 1.02e18);
    assertEq(adapter.latestAnswer(), 2_040e8);
    assertTrue(adapter.isCapped());
  }

  function test_rawRatioFailureWithoutLowerBound() public {
    ratioFeed.setLatestAnswer(0);
    assertEq(adapter.latestAnswer(), 0);
    assertTrue(adapter.isBreached());

    ratioFeed.setLatestAnswer(-1);
    assertEq(adapter.latestAnswer(), 0);
    assertTrue(adapter.isBreached());

    vm.mockCallRevert(address(ratioFeed), IChainlinkAggregator.latestAnswer.selector, 'fail');
    assertEq(adapter.getBoundedRatio(), 0);
    assertEq(adapter.latestAnswer(), 0);
    assertTrue(adapter.isBreached());
    assertFalse(adapter.isCapped());
    assertFalse(adapter.isFloored());
  }

  function test_rawRatioFailureWithLowerBound() public {
    _setLowerBound(0.95e18);

    vm.mockCallRevert(address(ratioFeed), IChainlinkAggregator.latestAnswer.selector, '');
    assertEq(adapter.latestAnswer(), 1_900e8);
    assertTrue(adapter.isFloored());
    assertTrue(adapter.isBreached());

    vm.mockCall(
      address(ratioFeed),
      IChainlinkAggregator.latestAnswer.selector,
      abi.encodePacked(uint8(1))
    );
    assertEq(adapter.latestAnswer(), 1_900e8);

    vm.clearMockedCalls();
    ratioFeed.setLatestAnswer(-1e18);
    assertEq(adapter.latestAnswer(), 1_900e8);

    skip(1 days);
    assertEq(adapter.latestAnswer(), 0);
  }

  function test_basePriceFailure() public {
    baseFeed.setLatestAnswer(0);
    assertEq(adapter.latestAnswer(), 0);

    baseFeed.setLatestAnswer(-1);
    assertEq(adapter.latestAnswer(), 0);

    baseFeed.setLatestAnswer(int256(uint256(type(uint128).max)) + 1);
    assertEq(adapter.latestAnswer(), 0);

    baseFeed.setLatestAnswer(int256(uint256(type(uint128).max)));
    assertGt(adapter.latestAnswer(), 0);

    vm.mockCallRevert(address(baseFeed), IChainlinkAggregator.latestAnswer.selector, 'fail');
    assertEq(adapter.latestAnswer(), 0);

    vm.mockCall(
      address(baseFeed),
      IChainlinkAggregator.latestAnswer.selector,
      abi.encodePacked(uint8(1))
    );
    assertEq(adapter.latestAnswer(), 0);
    assertFalse(adapter.isBreached());
  }

  function test_latestRoundData() public view {
    (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = adapter.latestRoundData();
    assertEq(roundId, 0);
    assertEq(answer, adapter.latestAnswer());
    assertEq(startedAt, block.timestamp);
    assertEq(updatedAt, block.timestamp);
    assertEq(answeredInRound, 0);
  }
}

contract BoundedRatioAdapterBaseFuzzTest is Test {
  ChainlinkAggregatorMock public baseFeed;
  ChainlinkAggregatorMock public ratioFeed;
  ACLManagerMock public aclManager;

  address public riskAdmin = address(0xDead);

  function setUp() public {
    skip(365 days + 1);
    baseFeed = new ChainlinkAggregatorMock(1e8);
    ratioFeed = new ChainlinkAggregatorMock(1e18);
    aclManager = new ACLManagerMock(address(0xBeef), riskAdmin);
  }

  function _deploy(
    address base,
    uint8 ratioDecimals,
    uint104 snapshotRatio,
    uint16 maxYearlyGrowth
  ) internal returns (BoundedRatioAdapterMock) {
    return
      new BoundedRatioAdapterMock(
        IBoundedRatioAdapter.BoundedRatioAdapterParams({
          aclManager: IACLManager(address(aclManager)),
          baseAggregatorAddress: base,
          ratioProviderAddress: address(ratioFeed),
          pairDescription: 'fuzz',
          ratioDecimals: ratioDecimals,
          minimumSnapshotDelay: 0,
          maximumLowerBoundDuration: 30 days,
          priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
            snapshotRatio: snapshotRatio,
            snapshotTimestamp: uint48(block.timestamp),
            maxYearlyRatioGrowthPercent: maxYearlyGrowth
          })
        })
      );
  }

  function testFuzz_upperBoundGrowth(
    uint104 snapshotRatio,
    uint16 maxYearlyGrowth,
    uint32 elapsed,
    uint32 extra
  ) public {
    snapshotRatio = uint104(bound(snapshotRatio, 1, type(uint104).max));
    BoundedRatioAdapterMock adapter = _deploy(address(0), 18, snapshotRatio, maxYearlyGrowth);

    skip(elapsed);
    uint256 maxRatio = adapter.getMaxRatio();
    uint256 linear = uint256(snapshotRatio) +
      (uint256(snapshotRatio) * maxYearlyGrowth * elapsed) /
      1e4 /
      365 days;

    uint256 growthScaled = (uint256(snapshotRatio) * maxYearlyGrowth * 1e6) / 1e4 / 365 days;

    assertEq(maxRatio, snapshotRatio + (growthScaled * elapsed) / 1e6);
    assertLe(maxRatio, linear);
    assertLe(linear - maxRatio, elapsed / 1e6 + 1);

    skip(extra);
    assertGe(adapter.getMaxRatio(), maxRatio);
  }

  function testFuzz_clamp(
    uint104 snapshotRatio,
    uint16 maxYearlyGrowth,
    int256 rawRatio,
    uint104 lowerBound,
    uint32 elapsed,
    uint32 boundAge
  ) public {
    snapshotRatio = uint104(bound(snapshotRatio, 1, type(uint104).max));
    BoundedRatioAdapterMock adapter = _deploy(address(0), 18, snapshotRatio, maxYearlyGrowth);

    ratioFeed.setLatestAnswer(int256(uint256(snapshotRatio)));
    lowerBound = uint104(bound(lowerBound, 0, snapshotRatio));
    vm.prank(riskAdmin);
    adapter.setLowerBound(lowerBound, uint48(block.timestamp + 30 days));

    skip(uint256(elapsed) + (boundAge % 60 days));
    ratioFeed.setLatestAnswer(rawRatio);

    uint256 bounded = adapter.getBoundedRatio();
    uint256 maxRatio = adapter.getMaxRatio();
    uint256 activeLower = adapter.getActiveLowerBound();
    uint256 raw = rawRatio > 0 ? uint256(rawRatio) : 0;

    assertLe(bounded, maxRatio);
    assertGe(bounded, activeLower < maxRatio ? activeLower : maxRatio);
    if (raw > 0 && raw >= activeLower && raw <= maxRatio) {
      assertEq(bounded, raw);
      assertFalse(adapter.isBreached());
    } else {
      assertTrue(adapter.isBreached());
    }
    assertEq(adapter.isCapped(), raw > maxRatio);
    assertEq(adapter.isFloored(), raw < activeLower);
    assertEq(adapter.latestAnswer(), int256(bounded / 1e10));
  }

  function testFuzz_priceNeverReverts(
    uint8 baseDecimals,
    uint8 ratioDecimals,
    int256 basePrice,
    int256 rawRatio,
    uint104 snapshotRatio,
    uint16 maxYearlyGrowth,
    uint32 elapsed
  ) public {
    baseDecimals = uint8(bound(baseDecimals, 0, 24));
    ratioDecimals = uint8(bound(ratioDecimals, 6, 24));
    snapshotRatio = uint104(bound(snapshotRatio, 1, type(uint104).max));
    baseFeed.setDecimals(baseDecimals);
    BoundedRatioAdapterMock adapter = _deploy(
      address(baseFeed),
      ratioDecimals,
      snapshotRatio,
      maxYearlyGrowth
    );

    baseFeed.setLatestAnswer(basePrice);
    ratioFeed.setLatestAnswer(rawRatio);
    skip(elapsed);

    int256 price = adapter.latestAnswer();
    assertGe(price, 0);

    uint256 bounded = adapter.getBoundedRatio();
    if (basePrice <= 0 || basePrice > int256(uint256(type(uint128).max)) || bounded == 0) {
      assertEq(price, 0);
    } else {
      uint256 decimals = uint256(baseDecimals) + ratioDecimals;
      uint256 expected = decimals >= 8
        ? (uint256(basePrice) * bounded) / 10 ** (decimals - 8)
        : uint256(basePrice) * bounded * 10 ** (8 - decimals);
      assertEq(uint256(price), expected);
    }
  }

  function testFuzz_lowerBoundNeverRaisesPrice(
    int256 rawRatio,
    uint104 lowerBound,
    uint32 expirationDelay
  ) public {
    BoundedRatioAdapterMock adapter = _deploy(address(baseFeed), 18, 1e18, 10_00);
    skip(30 days);
    rawRatio = bound(rawRatio, -1, 2e18);
    ratioFeed.setLatestAnswer(rawRatio);
    uint48 expiration = uint48(block.timestamp + bound(expirationDelay, 1, 30 days));

    int256 priceBefore = adapter.latestAnswer();
    vm.prank(riskAdmin);
    try adapter.setLowerBound(lowerBound, expiration) {
      assertLe(adapter.latestAnswer(), priceBefore);
      assertEq(adapter.getActiveLowerBound(), lowerBound);
    } catch {
      assertGt(lowerBound, adapter.getBoundedRatio());
    }
  }
}
