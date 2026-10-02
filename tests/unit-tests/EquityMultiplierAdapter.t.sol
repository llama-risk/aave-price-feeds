// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from 'forge-std/Test.sol';

import {IEquityMultiplierAdapter, IBoundedRatioAdapter, IPriceCapAdapter, IACLManager} from '../../src/interfaces/IEquityMultiplierAdapter.sol';
import {EquityMultiplierAdapter} from '../../src/contracts/misc-adapters/EquityMultiplierAdapter.sol';

import {ChainlinkAggregatorMock} from './mocks/ChainlinkAggregatorMock.sol';
import {ACLManagerMock} from './mocks/ACLManagerMock.sol';
import {B20OracleRegistryMock} from './mocks/B20OracleRegistryMock.sol';
import {SpokeMock} from './mocks/SpokeMock.sol';

contract EquityMultiplierAdapterTest is Test {
  ChainlinkAggregatorMock public baseFeed;
  B20OracleRegistryMock public registry;
  SpokeMock public spoke;
  ACLManagerMock public aclManager;

  EquityMultiplierAdapter public adapter;

  address public token = makeAddr('token');
  address public riskAdmin = address(0xDead);
  address public poolAdmin = address(0xBeef);

  uint256 public constant RESERVE_ID = 3;
  int256 public constant BASE_PRICE = 300e8;
  uint104 public constant MULTIPLIER = 1e18;
  uint16 public constant YEARLY_GROWTH = 5_00;
  uint16 public constant YEARLY_GROWTH_LIMIT = 10_00;
  uint256 public constant HEADROOM_TERM = 73 days;

  function setUp() public {
    skip(365 days);

    baseFeed = new ChainlinkAggregatorMock(BASE_PRICE);
    registry = new B20OracleRegistryMock();
    registry.setMultiplier(token, MULTIPLIER);
    spoke = new SpokeMock();
    spoke.setUnderlying(RESERVE_ID, token);
    aclManager = new ACLManagerMock(poolAdmin, riskAdmin);

    adapter = new EquityMultiplierAdapter(_params());
  }

  function _params()
    internal
    view
    returns (IEquityMultiplierAdapter.EquityMultiplierAdapterParams memory)
  {
    return
      IEquityMultiplierAdapter.EquityMultiplierAdapterParams({
        aclManager: IACLManager(address(aclManager)),
        baseAggregatorAddress: address(baseFeed),
        registry: address(registry),
        token: token,
        spoke: address(spoke),
        reserveId: RESERVE_ID,
        pairDescription: 'METAc / USD',
        minimumSnapshotDelay: 0,
        maximumLowerBoundDuration: 7 days,
        maximumYearlyRatioGrowthPercent: YEARLY_GROWTH_LIMIT,
        priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
          snapshotRatio: MULTIPLIER,
          snapshotTimestamp: uint48(block.timestamp - HEADROOM_TERM),
          maxYearlyRatioGrowthPercent: YEARLY_GROWTH
        })
      });
  }

  function _capParams(
    uint256 snapshotRatio,
    uint256 snapshotTimestamp,
    uint16 maxYearlyGrowth
  ) internal pure returns (IPriceCapAdapter.PriceCapUpdateParams memory) {
    return
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: uint104(snapshotRatio),
        snapshotTimestamp: uint48(snapshotTimestamp),
        maxYearlyRatioGrowthPercent: maxYearlyGrowth
      });
  }

  function _setCap(uint256 snapshotRatio, uint256 snapshotTimestamp, uint16 growth) internal {
    vm.prank(riskAdmin);
    adapter.setCapParameters(_capParams(snapshotRatio, snapshotTimestamp, growth));
  }

  function _price(uint256 multiplier) internal pure returns (int256) {
    return int256((uint256(BASE_PRICE) * multiplier) / 1e18);
  }

  function test_setup() public view {
    assertEq(adapter.TOKEN(), token);
    assertEq(address(adapter.SPOKE()), address(spoke));
    assertEq(adapter.RESERVE_ID(), RESERVE_ID);
    assertEq(adapter.MAXIMUM_YEARLY_RATIO_GROWTH_PERCENT(), YEARLY_GROWTH_LIMIT);
    assertEq(adapter.RATIO_PROVIDER(), address(registry));
    assertEq(adapter.RATIO_DECIMALS(), 18);
    assertEq(adapter.decimals(), 8);
    assertEq(adapter.description(), 'METAc / USD');
    assertEq(adapter.getRatio(), int256(uint256(MULTIPLIER)));
    assertApproxEqRel(adapter.getMaxRatio(), 1.01e18, 1e9);
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertFalse(adapter.isReservePaused());
    assertFalse(adapter.isBreached());

    (, int256 answer, uint256 startedAt, uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, BASE_PRICE);
    assertEq(startedAt, block.timestamp);
    assertEq(updatedAt, baseFeed.latestTimestamp());
  }

  function test_constructorReverts() public {
    IEquityMultiplierAdapter.EquityMultiplierAdapterParams memory params = _params();
    params.baseAggregatorAddress = address(0);
    vm.expectRevert(IEquityMultiplierAdapter.BaseAggregatorIsZeroAddress.selector);
    new EquityMultiplierAdapter(params);

    params = _params();
    params.token = address(0);
    vm.expectRevert(IEquityMultiplierAdapter.TokenIsZeroAddress.selector);
    new EquityMultiplierAdapter(params);

    address other = makeAddr('other');
    spoke.setUnderlying(RESERVE_ID + 1, other);
    params = _params();
    params.reserveId = RESERVE_ID + 1;
    vm.expectRevert(
      abi.encodeWithSelector(IEquityMultiplierAdapter.ReserveUnderlyingMismatch.selector, other)
    );
    new EquityMultiplierAdapter(params);

    params = _params();
    params.reserveId = RESERVE_ID + 2;
    vm.expectRevert();
    new EquityMultiplierAdapter(params);

    params = _params();
    params.registry = address(0);
    vm.expectRevert(IBoundedRatioAdapter.RatioProviderIsZeroAddress.selector);
    new EquityMultiplierAdapter(params);

    params = _params();
    params.priceCapParams.snapshotRatio = MULTIPLIER + 1;
    vm.expectRevert(
      abi.encodeWithSelector(
        IEquityMultiplierAdapter.SnapshotRatioOutsideWindow.selector,
        MULTIPLIER + 1
      )
    );
    new EquityMultiplierAdapter(params);

    registry.setMultiplier(token, uint256(type(uint104).max) + 1);
    vm.expectRevert(IEquityMultiplierAdapter.InvalidMultiplier.selector);
    new EquityMultiplierAdapter(_params());

    registry.setMultiplier(token, 0);
    vm.expectRevert();
    new EquityMultiplierAdapter(_params());
    registry.setMultiplier(token, MULTIPLIER);

    params = _params();
    params.priceCapParams.maxYearlyRatioGrowthPercent = YEARLY_GROWTH_LIMIT + 1;
    vm.expectRevert(
      abi.encodeWithSelector(
        IEquityMultiplierAdapter.MaxYearlyRatioGrowthPercentAboveLimit.selector,
        YEARLY_GROWTH_LIMIT + 1
      )
    );
    new EquityMultiplierAdapter(params);
  }

  function test_dividendInsideWindow() public {
    registry.setMultiplier(token, 1.00313792289598084e18);
    assertEq(adapter.getBoundedRatio(), 1.00313792289598084e18);
    assertEq(adapter.latestAnswer(), _price(1.00313792289598084e18));
    assertFalse(adapter.isBreached());
  }

  function test_increaseAboveWindowIsClamped() public {
    registry.setMultiplier(token, 1.05e18);
    uint256 maxRatio = adapter.getMaxRatio();
    assertEq(adapter.getBoundedRatio(), maxRatio);
    assertEq(adapter.latestAnswer(), _price(maxRatio));
    assertTrue(adapter.isCapped());
    assertTrue(adapter.isBreached());
  }

  function test_decreaseIsPricedAtRawMultiplier() public {
    registry.setMultiplier(token, 0.5e18);
    assertEq(adapter.getBoundedRatio(), 0.5e18);
    assertEq(adapter.latestAnswer(), BASE_PRICE / 2);
    assertFalse(adapter.isFloored());
    assertTrue(adapter.isBreached());
  }

  function test_lowerBoundDoesNotFloorLiveMultiplier() public {
    registry.setMultiplier(token, 1.005e18);
    vm.prank(riskAdmin);
    adapter.setLowerBound(1.004e18, uint48(block.timestamp + 1 days));

    registry.setMultiplier(token, 1.002e18);
    assertEq(adapter.getBoundedRatio(), 1.002e18);
    assertFalse(adapter.isBreached());

    registry.setReverts(true);
    assertEq(adapter.getBoundedRatio(), MULTIPLIER);
    assertTrue(adapter.isFloored());
    assertTrue(adapter.isBreached());
  }

  function test_registryFailure() public {
    registry.setReverts(true);
    assertEq(adapter.latestAnswer(), 0);
    assertTrue(adapter.isBreached());
    (, int256 answer, , uint256 updatedAt, ) = adapter.latestRoundData();
    assertEq(answer, 0);
    assertEq(updatedAt, 0);

    vm.prank(riskAdmin);
    vm.expectRevert(
      abi.encodeWithSelector(IBoundedRatioAdapter.InvalidLowerBound.selector, MULTIPLIER + 1)
    );
    adapter.setLowerBound(MULTIPLIER + 1, uint48(block.timestamp + 1 days));

    vm.prank(riskAdmin);
    adapter.setLowerBound(MULTIPLIER, uint48(block.timestamp + 1 days));
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertTrue(adapter.isBreached());
  }

  function test_baseFeedFailure() public {
    baseFeed.setLatestAnswer(0);
    assertEq(adapter.latestAnswer(), 0);

    vm.mockCallRevert(address(baseFeed), abi.encodeWithSignature('latestAnswer()'), '');
    assertEq(adapter.latestAnswer(), 0);
  }

  function test_acceptMultiplierInsideWindow() public {
    uint256 maxRatio = adapter.getMaxRatio();
    registry.setMultiplier(token, 1.004e18);

    _setCap(1.004e18, block.timestamp - 1 days, YEARLY_GROWTH);
    assertEq(adapter.getSnapshotRatio(), 1.004e18);
    assertLe(adapter.getMaxRatio(), maxRatio);

    registry.setMultiplier(token, 1.003e18);
    assertEq(adapter.getBoundedRatio(), 1.003e18);
    assertTrue(adapter.isBreached());
  }

  function test_acceptKeepsMaxRatio() public {
    uint256 maxRatio = adapter.getMaxRatio();
    registry.setMultiplier(token, 1.004e18);

    uint256 term = ((maxRatio - 1.004e18) * 365 days) / ((1.004e18 * uint256(YEARLY_GROWTH)) / 1e4);
    _setCap(1.004e18, block.timestamp - term, YEARLY_GROWTH);
    assertApproxEqRel(adapter.getMaxRatio(), maxRatio, 1e9);
    assertLe(adapter.getMaxRatio(), maxRatio);
  }

  function test_normalModeRejectsDecrease() public {
    registry.setMultiplier(token, 0.9e18);
    vm.expectRevert(
      abi.encodeWithSelector(IEquityMultiplierAdapter.SnapshotRatioOutsideWindow.selector, 0.9e18)
    );
    _setCap(0.9e18, block.timestamp - 1 days, YEARLY_GROWTH);
  }

  function test_normalModeRejectsAboveRawRatio() public {
    registry.setMultiplier(token, 1.002e18);
    vm.expectRevert(
      abi.encodeWithSelector(IEquityMultiplierAdapter.SnapshotRatioOutsideWindow.selector, 1.003e18)
    );
    _setCap(1.003e18, block.timestamp - 1 days, YEARLY_GROWTH);
  }

  function test_normalModeRejectsInvalidRawRatio() public {
    registry.setReverts(true);
    vm.expectRevert(
      abi.encodeWithSelector(
        IEquityMultiplierAdapter.SnapshotRatioOutsideWindow.selector,
        MULTIPLIER
      )
    );
    _setCap(MULTIPLIER, block.timestamp - 1 days, YEARLY_GROWTH);
  }

  function test_normalModeRejectsMaxRatioIncrease() public {
    vm.prank(riskAdmin);
    vm.expectPartialRevert(IEquityMultiplierAdapter.MaxRatioIncrease.selector);
    adapter.setCapParameters(_capParams(MULTIPLIER, block.timestamp - 146 days, YEARLY_GROWTH));

    vm.prank(riskAdmin);
    vm.expectPartialRevert(IEquityMultiplierAdapter.MaxRatioIncrease.selector);
    adapter.setCapParameters(
      _capParams(MULTIPLIER, block.timestamp - HEADROOM_TERM + 1, YEARLY_GROWTH_LIMIT)
    );

    registry.setMultiplier(token, 1.01e18);
    vm.prank(riskAdmin);
    vm.expectPartialRevert(IEquityMultiplierAdapter.MaxRatioIncrease.selector);
    adapter.setCapParameters(_capParams(1.01e18, block.timestamp - 1 days, YEARLY_GROWTH));
  }

  function test_growthLimitInEveryMode() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IEquityMultiplierAdapter.MaxYearlyRatioGrowthPercentAboveLimit.selector,
        YEARLY_GROWTH_LIMIT + 1
      )
    );
    _setCap(MULTIPLIER, block.timestamp - 1 days, YEARLY_GROWTH_LIMIT + 1);

    spoke.setPaused(RESERVE_ID, true);
    vm.expectRevert(
      abi.encodeWithSelector(
        IEquityMultiplierAdapter.MaxYearlyRatioGrowthPercentAboveLimit.selector,
        YEARLY_GROWTH_LIMIT + 1
      )
    );
    _setCap(MULTIPLIER, block.timestamp - 1 days, YEARLY_GROWTH_LIMIT + 1);
  }

  function test_splitWhilePaused() public {
    registry.setMultiplier(token, 2e18);
    baseFeed.setLatestAnswer(BASE_PRICE / 2);
    assertTrue(adapter.isBreached());
    assertEq(
      adapter.latestAnswer(),
      int256((uint256(BASE_PRICE / 2) * adapter.getMaxRatio()) / 1e18)
    );

    vm.expectPartialRevert(IEquityMultiplierAdapter.MaxRatioIncrease.selector);
    _setCap(2e18, block.timestamp - 1 days, YEARLY_GROWTH);

    spoke.setPaused(RESERVE_ID, true);
    assertTrue(adapter.isReservePaused());
    _setCap(2e18, block.timestamp - 1 days, YEARLY_GROWTH);
    spoke.setPaused(RESERVE_ID, false);

    assertEq(adapter.getBoundedRatio(), 2e18);
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertFalse(adapter.isBreached());
  }

  function test_reverseSplitWhilePaused() public {
    registry.setMultiplier(token, 0.1e18);
    baseFeed.setLatestAnswer(BASE_PRICE * 10);
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertTrue(adapter.isBreached());

    spoke.setPaused(RESERVE_ID, true);
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    _setCap(0.1e18, block.timestamp - 1 days, YEARLY_GROWTH);
    spoke.setPaused(RESERVE_ID, false);

    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertFalse(adapter.isBreached());
  }

  function test_reverseSplitWithActiveLowerBound() public {
    vm.prank(riskAdmin);
    adapter.setLowerBound(MULTIPLIER, uint48(block.timestamp + 7 days));

    registry.setMultiplier(token, 0.1e18);
    baseFeed.setLatestAnswer(BASE_PRICE * 10);
    assertEq(adapter.latestAnswer(), BASE_PRICE);

    spoke.setPaused(RESERVE_ID, true);
    _setCap(0.1e18, block.timestamp - 1 days, YEARLY_GROWTH);
    spoke.setPaused(RESERVE_ID, false);
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertFalse(adapter.isBreached());

    registry.setReverts(true);
    assertEq(adapter.getBoundedRatio(), 0.1e18);
    assertEq(adapter.latestAnswer(), BASE_PRICE);
  }

  function test_spokeFailureIsNormalMode() public {
    spoke.setPaused(RESERVE_ID, true);
    spoke.setReverts(true);
    assertFalse(adapter.isReservePaused());

    registry.setMultiplier(token, 2e18);
    vm.expectPartialRevert(IEquityMultiplierAdapter.MaxRatioIncrease.selector);
    _setCap(2e18, block.timestamp - 1 days, YEARLY_GROWTH);
  }

  function test_issuerPauseIsBreach() public {
    registry.setPaused(token, true);
    assertTrue(adapter.isIssuerPaused());
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertTrue(adapter.isBreached());

    registry.setMultiplier(token, 1.002e18);
    vm.expectRevert(IEquityMultiplierAdapter.IssuerPaused.selector);
    _setCap(1.002e18, block.timestamp - 1 days, YEARLY_GROWTH);

    spoke.setPaused(RESERVE_ID, true);
    _setCap(1.002e18, block.timestamp - 1 days, YEARLY_GROWTH);
    assertEq(adapter.getSnapshotRatio(), 1.002e18);

    registry.setPaused(token, false);
    assertFalse(adapter.isBreached());
  }

  function test_onlyRiskOrPoolAdmin() public {
    vm.expectRevert(IPriceCapAdapter.CallerIsNotRiskOrPoolAdmin.selector);
    adapter.setCapParameters(_capParams(MULTIPLIER, block.timestamp - 1 days, YEARLY_GROWTH));

    spoke.setPaused(RESERVE_ID, true);
    vm.expectRevert(IPriceCapAdapter.CallerIsNotRiskOrPoolAdmin.selector);
    adapter.setCapParameters(_capParams(2e18, block.timestamp - 1 days, YEARLY_GROWTH));

    vm.prank(poolAdmin);
    adapter.setCapParameters(_capParams(2e18, block.timestamp - 1 days, YEARLY_GROWTH));
    assertEq(adapter.getSnapshotRatio(), 2e18);
  }

  function testFuzz_ratioStaysInWindow(uint256 multiplier, uint32 elapsed) public {
    multiplier = bound(multiplier, 1, 1e30);
    skip(elapsed);
    registry.setMultiplier(token, multiplier);

    uint256 ratio = adapter.getBoundedRatio();
    uint256 maxRatio = adapter.getMaxRatio();
    assertEq(ratio, multiplier < maxRatio ? multiplier : maxRatio);
    assertEq(adapter.latestAnswer(), _price(ratio));
    assertEq(adapter.isBreached(), multiplier < MULTIPLIER || multiplier > maxRatio);
  }

  function testFuzz_normalModeNeverRaisesMaxRatio(
    uint256 multiplier,
    uint256 snapshotRatio,
    uint256 term,
    uint16 growth
  ) public {
    multiplier = bound(multiplier, MULTIPLIER, 1.1e18);
    snapshotRatio = bound(snapshotRatio, 1, 1.1e18);
    term = bound(term, 0, 180 days);
    growth = uint16(bound(growth, 0, YEARLY_GROWTH_LIMIT));
    registry.setMultiplier(token, multiplier);
    uint256 maxRatio = adapter.getMaxRatio();

    vm.prank(riskAdmin);
    try adapter.setCapParameters(_capParams(snapshotRatio, block.timestamp - term, growth)) {
      assertLe(adapter.getMaxRatio(), maxRatio);
      assertGe(adapter.getSnapshotRatio(), MULTIPLIER);
      assertLe(adapter.getSnapshotRatio(), multiplier);
    } catch {}
  }
}
