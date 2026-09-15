// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import {IEquityPriceCapAdapter, IEquityMultiplier} from '../src/interfaces/IEquityPriceCapAdapter.sol';
import {EquityPriceCapAdapter} from '../src/contracts/equity-adapters/EquityPriceCapAdapter.sol';
import {B20EquityMultiplier} from '../src/contracts/equity-adapters/B20EquityMultiplier.sol';

contract EquityUnitTest is Test {
  MockChainlink underlying;
  MockACL aclManager;
  MockB20 token;
  B20EquityMultiplier multiplierSource;

  EquityPriceCapAdapter adapter;

  address riskAdmin = address(0xDead);
  address poolAdmin = address(0xBeef);
  address updater = address(0xCAFE);
  address stranger = address(0x1234);

  // 100 USD at 8 decimals, the scale every Chainlink equity feed in this market uses
  int256 constant BASE_PRICE = 100e8;
  uint16 constant DEVIATION_BPS = 1_000; // 10%

  function setUp() public {
    underlying = new MockChainlink();
    aclManager = new MockACL();
    token = new MockB20();

    underlying.setDecimals(8);
    underlying.setLatestAnswer(BASE_PRICE);
    aclManager.setAdmins(riskAdmin, poolAdmin);
    token.setMultiplier(1e18);

    multiplierSource = new B20EquityMultiplier(address(token));
    adapter = new EquityPriceCapAdapter(_params());
  }

  function _params()
    internal
    view
    returns (IEquityPriceCapAdapter.EquityPriceCapAdapterParams memory)
  {
    return
      IEquityPriceCapAdapter.EquityPriceCapAdapterParams({
        assetToUsdAggregator: address(underlying),
        equityMultiplier: address(multiplierSource),
        aclManager: address(aclManager),
        referenceUpdater: updater,
        maxDeviationBps: DEVIATION_BPS,
        minReferenceDelay: 1 hours,
        description: 'Capped AAPLc / USD'
      });
  }

  // --- construction ---

  function test_construct() external view {
    assertEq(address(adapter.ASSET_TO_USD_AGGREGATOR()), address(underlying));
    assertEq(address(adapter.EQUITY_MULTIPLIER()), address(multiplierSource));
    assertEq(address(adapter.ACL_MANAGER()), address(aclManager));
    assertEq(adapter.MULTIPLIER_DECIMALS(), 18);
    assertEq(adapter.MIN_REFERENCE_DELAY(), 1 hours);
    assertEq(adapter.maxDeviationBps(), DEVIATION_BPS);
    assertEq(adapter.referenceUpdater(), updater);
    assertEq(adapter.decimals(), 8);
    assertEq(adapter.description(), 'Capped AAPLc / USD');
    // seeded from the live price, not from a governance snapshot
    assertEq(adapter.referencePrice(), uint256(BASE_PRICE));
  }

  function test_construct_revertsOnZeroAddress() external {
    IEquityPriceCapAdapter.EquityPriceCapAdapterParams memory params = _params();

    params.assetToUsdAggregator = address(0);
    vm.expectRevert(IEquityPriceCapAdapter.ZeroAddress.selector);
    new EquityPriceCapAdapter(params);

    params = _params();
    params.equityMultiplier = address(0);
    vm.expectRevert(IEquityPriceCapAdapter.ZeroAddress.selector);
    new EquityPriceCapAdapter(params);

    params = _params();
    params.aclManager = address(0);
    vm.expectRevert(IEquityPriceCapAdapter.ZeroAddress.selector);
    new EquityPriceCapAdapter(params);
  }

  function test_construct_revertsOnInvalidDeviation() external {
    IEquityPriceCapAdapter.EquityPriceCapAdapterParams memory params = _params();

    params.maxDeviationBps = 0;
    vm.expectRevert(IEquityPriceCapAdapter.InvalidMaxDeviationBps.selector);
    new EquityPriceCapAdapter(params);

    uint16 aboveLimit = adapter.MAX_DEVIATION_BPS_LIMIT() + 1;
    params.maxDeviationBps = aboveLimit;
    vm.expectRevert(IEquityPriceCapAdapter.InvalidMaxDeviationBps.selector);
    new EquityPriceCapAdapter(params);
  }

  function test_construct_revertsWhenUnderlyingUnusable() external {
    underlying.setLatestAnswer(0);

    vm.expectRevert(IEquityPriceCapAdapter.InvalidReferencePrice.selector);
    new EquityPriceCapAdapter(_params());
  }

  // --- pricing ---

  function test_latestAnswer_insideBand() external view {
    assertEq(adapter.latestAnswer(), BASE_PRICE);
    assertFalse(adapter.isCapped());
  }

  function test_latestAnswer_appliesMultiplier() external {
    // a 3-for-1 split: 200% jump in one write, which is legitimate and enormous
    token.setMultiplier(3e18);

    assertEq(adapter.getRawPrice(), uint256(BASE_PRICE) * 3);
    // the band does not know the difference between a split and a compromise, so it clamps
    assertTrue(adapter.isCapped());
    assertEq(adapter.latestAnswer(), int256((uint256(BASE_PRICE) * 11_000) / 10_000));
  }

  function test_latestAnswer_clampsBelow() external {
    // a 30% fall, deeper than the 10% band
    underlying.setLatestAnswer(70e8);

    assertTrue(adapter.isCapped());
    assertEq(adapter.latestAnswer(), int256((uint256(BASE_PRICE) * 9_000) / 10_000));
  }

  function test_latestAnswer_clampsAbove() external {
    underlying.setLatestAnswer(130e8);

    assertTrue(adapter.isCapped());
    assertEq(adapter.latestAnswer(), int256((uint256(BASE_PRICE) * 11_000) / 10_000));
  }

  function test_latestAnswer_atBandEdgesIsNotCapped() external {
    (uint256 lowerBound, uint256 upperBound) = adapter.getBounds();

    underlying.setLatestAnswer(int256(lowerBound));
    assertFalse(adapter.isCapped());
    assertEq(adapter.latestAnswer(), int256(lowerBound));

    underlying.setLatestAnswer(int256(upperBound));
    assertFalse(adapter.isCapped());
    assertEq(adapter.latestAnswer(), int256(upperBound));
  }

  function test_latestAnswer_zeroWhenUnderlyingUnusable() external {
    underlying.setLatestAnswer(0);
    assertEq(adapter.latestAnswer(), 0);
    assertFalse(adapter.isCapped());

    underlying.setLatestAnswer(-1);
    assertEq(adapter.latestAnswer(), 0);
    assertFalse(adapter.isCapped());
  }

  function test_latestAnswer_zeroWhenMultiplierUnusable() external {
    token.setMultiplier(0);

    assertEq(adapter.getRawPrice(), 0);
    assertEq(adapter.latestAnswer(), 0);
    assertFalse(adapter.isCapped());
  }

  /// @dev GOOGLc on Base reads 1000377118676784000, not 1e18. Anything asserting exactly 1e18 is
  ///      wrong on the first read, so the arithmetic is pinned against the real value.
  function test_latestAnswer_nonUnitBaselineMultiplier() external {
    token.setMultiplier(1_000377118676784000);

    assertEq(adapter.getRawPrice(), (uint256(BASE_PRICE) * 1_000377118676784000) / 1e18);
    assertFalse(adapter.isCapped());
  }

  // --- reference ---

  function test_updateReferencePrice() external {
    underlying.setLatestAnswer(105e8);
    skip(1 hours);

    vm.prank(updater);
    adapter.updateReferencePrice();

    assertEq(adapter.referencePrice(), 105e8);
    assertEq(adapter.referenceTimestamp(), uint48(block.timestamp));
  }

  /// @dev The reference must advance to the raw price, never the clamped one: advancing to the
  ///      clamp lets the band walk toward a manipulated price one valid-looking step at a time.
  function test_updateReferencePrice_movesToRawNotClamped() external {
    underlying.setLatestAnswer(200e8);
    skip(1 hours);

    vm.prank(updater);
    adapter.updateReferencePrice();

    assertEq(adapter.referencePrice(), 200e8);
    assertFalse(adapter.isCapped());
  }

  function test_updateReferencePrice_respectsDelay() external {
    vm.prank(updater);
    vm.expectRevert(IEquityPriceCapAdapter.ReferenceUpdatedTooRecently.selector);
    adapter.updateReferencePrice();

    skip(1 hours);
    vm.prank(updater);
    adapter.updateReferencePrice();
  }

  function test_updateReferencePrice_adminsMayAlsoCall() external {
    skip(1 hours);
    vm.prank(riskAdmin);
    adapter.updateReferencePrice();

    skip(1 hours);
    vm.prank(poolAdmin);
    adapter.updateReferencePrice();
  }

  function test_updateReferencePrice_revertsForStranger() external {
    skip(1 hours);

    vm.prank(stranger);
    vm.expectRevert(IEquityPriceCapAdapter.CallerIsNotReferenceUpdater.selector);
    adapter.updateReferencePrice();
  }

  function test_updateReferencePrice_revertsWhenUnderlyingUnusable() external {
    skip(1 hours);
    underlying.setLatestAnswer(0);

    vm.prank(updater);
    vm.expectRevert(IEquityPriceCapAdapter.InvalidReferencePrice.selector);
    adapter.updateReferencePrice();
  }

  // --- admin ---

  function test_setMaxDeviationBps() external {
    vm.prank(riskAdmin);
    adapter.setMaxDeviationBps(2_000);
    assertEq(adapter.maxDeviationBps(), 2_000);

    (uint256 lowerBound, uint256 upperBound) = adapter.getBounds();
    assertEq(lowerBound, (uint256(BASE_PRICE) * 8_000) / 10_000);
    assertEq(upperBound, (uint256(BASE_PRICE) * 12_000) / 10_000);
  }

  function test_setMaxDeviationBps_revertsForStranger() external {
    vm.prank(stranger);
    vm.expectRevert(IEquityPriceCapAdapter.CallerIsNotRiskOrPoolAdmin.selector);
    adapter.setMaxDeviationBps(2_000);
  }

  function test_setMaxDeviationBps_revertsOnInvalid() external {
    vm.startPrank(riskAdmin);

    vm.expectRevert(IEquityPriceCapAdapter.InvalidMaxDeviationBps.selector);
    adapter.setMaxDeviationBps(0);

    uint16 aboveLimit = adapter.MAX_DEVIATION_BPS_LIMIT() + 1;
    vm.expectRevert(IEquityPriceCapAdapter.InvalidMaxDeviationBps.selector);
    adapter.setMaxDeviationBps(aboveLimit);

    vm.stopPrank();
  }

  function test_setReferenceUpdater() external {
    vm.prank(poolAdmin);
    adapter.setReferenceUpdater(stranger);
    assertEq(adapter.referenceUpdater(), stranger);

    skip(1 hours);
    vm.prank(stranger);
    adapter.updateReferencePrice();
  }

  function test_setReferenceUpdater_revertsForStranger() external {
    vm.prank(stranger);
    vm.expectRevert(IEquityPriceCapAdapter.CallerIsNotRiskOrPoolAdmin.selector);
    adapter.setReferenceUpdater(stranger);
  }

  // --- B20 multiplier source ---

  function test_b20Multiplier() external view {
    assertEq(multiplierSource.multiplier(), 1e18);
    assertEq(multiplierSource.multiplierDecimals(), 18);
    assertEq(address(multiplierSource.TOKEN()), address(token));
  }

  function test_b20Multiplier_revertsOnZeroAddress() external {
    vm.expectRevert(B20EquityMultiplier.ZeroAddress.selector);
    new B20EquityMultiplier(address(0));
  }

  function test_b20Multiplier_revertsOnZeroMultiplierAtDeploy() external {
    MockB20 broken = new MockB20();
    broken.setMultiplier(0);

    vm.expectRevert(B20EquityMultiplier.InvalidMultiplier.selector);
    new B20EquityMultiplier(address(broken));
  }

  // --- fuzz ---

  function testFuzz_latestAnswerAlwaysWithinBounds(int256 price, uint256 multiplier) external {
    price = bound(price, 1, 1e18);
    multiplier = bound(multiplier, 1, 1e24);

    underlying.setLatestAnswer(price);
    token.setMultiplier(multiplier);

    (uint256 lowerBound, uint256 upperBound) = adapter.getBounds();
    int256 answer = adapter.latestAnswer();

    if (answer == 0) {
      // only when a leg is unusable, which bound() excludes, so the product underflowed to zero
      assertEq(adapter.getRawPrice(), 0);
      return;
    }

    assertGe(uint256(answer), lowerBound);
    assertLe(uint256(answer), upperBound);
  }
}

contract MockChainlink {
  int256 internal _latestAnswer;
  uint8 internal _decimals;

  function setLatestAnswer(int256 answer) external {
    _latestAnswer = answer;
  }

  function setDecimals(uint8 decimals_) external {
    _decimals = decimals_;
  }

  function latestAnswer() external view returns (int256) {
    return _latestAnswer;
  }

  function decimals() external view returns (uint8) {
    return _decimals;
  }
}

contract MockACL {
  address internal _riskAdmin;
  address internal _poolAdmin;

  function setAdmins(address riskAdmin, address poolAdmin) external {
    _riskAdmin = riskAdmin;
    _poolAdmin = poolAdmin;
  }

  function isRiskAdmin(address admin) external view returns (bool) {
    return admin == _riskAdmin;
  }

  function isPoolAdmin(address admin) external view returns (bool) {
    return admin == _poolAdmin;
  }
}

contract MockB20 {
  uint256 internal _multiplier;

  function setMultiplier(uint256 multiplier_) external {
    _multiplier = multiplier_;
  }

  function multiplier() external view returns (uint256) {
    return _multiplier;
  }
}
