// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from 'forge-std/Test.sol';
import {AaveV3Base} from 'aave-address-book/AaveV3Base.sol';

import {IEquityMultiplierAdapter, IPriceCapAdapter, IChainlinkAggregator} from '../src/interfaces/IEquityMultiplierAdapter.sol';
import {IB20OracleRegistry} from '../src/interfaces/IB20OracleRegistry.sol';
import {EquityMultiplierAdapter} from '../src/contracts/misc-adapters/EquityMultiplierAdapter.sol';

interface IAaveV4Oracle {
  function setReserveSource(uint256 reserveId, address source) external;

  function getReservePrice(uint256 reserveId) external view returns (uint256);
}

interface IAccessManager {
  function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
}

interface ISpokeConfigurator {
  function updatePaused(address spoke, uint256 reserveId, bool paused) external;
}

contract EquityMultiplierAdapterForkTest is Test {
  uint256 public constant BLOCK = 52071000;
  string public constant BLOCK_HEX = '0x31a8d18';

  IB20OracleRegistry public constant REGISTRY =
    IB20OracleRegistry(0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD);
  address public constant GOOGLc = 0xb2000000000000000000002D0BA3164cc74f58B7;
  address public constant MAG7_SPOKE_GOOGLc_PRICE_FEED = 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2;
  uint256 public constant GOOGLc_RESERVE_ID = 2;

  address public constant MAG7_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
  IAaveV4Oracle public constant MAG7_SPOKE_ORACLE =
    IAaveV4Oracle(0xaBaf048fD7675Ea34a84332371ffd5D55E322A47);
  IAccessManager public constant ACCESS_MANAGER =
    IAccessManager(0x4010C94698EDE9d895814502B6EB122D764a1Cc6);
  address public constant ACCESS_MANAGER_ADMIN = 0x187AAE17d4931310B3fc75743e7F16Bdc9eD77e9;
  ISpokeConfigurator public constant SPOKE_CONFIGURATOR =
    ISpokeConfigurator(0x0191B1Aa743c6B3C545119B5D56a0577D7f3a57F);
  uint64 public constant SPOKE_CONFIGURATOR_ROLE = 400;

  bytes4 public constant B20_MULTIPLIER_SELECTOR = 0x1b3ed722;

  address public boundsAgent = makeAddr('boundsAgent');
  address public pauser = makeAddr('pauser');

  EquityMultiplierAdapter public adapter;
  uint256 public liveMultiplier;
  bool public livePaused;
  uint256 public basePrice;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('base'), BLOCK);

    // B20 tokens are a Base precompile the local EVM cannot run: mirror the live multiplier
    bytes memory registryAnswer = vm.rpc(
      'eth_call',
      string.concat(
        '[{"to":"',
        vm.toString(address(REGISTRY)),
        '","data":"',
        vm.toString(abi.encodeCall(IB20OracleRegistry.getOracleParams, (GOOGLc))),
        '"},"',
        BLOCK_HEX,
        '"]'
      )
    );
    (liveMultiplier, livePaused) = abi.decode(registryAnswer, (uint256, bool));
    _mockMultiplier(liveMultiplier);

    basePrice = uint256(IChainlinkAggregator(MAG7_SPOKE_GOOGLc_PRICE_FEED).latestAnswer());

    vm.prank(AaveV3Base.ACL_ADMIN);
    AaveV3Base.ACL_MANAGER.addRiskAdmin(boundsAgent);

    vm.prank(ACCESS_MANAGER_ADMIN);
    ACCESS_MANAGER.grantRole(SPOKE_CONFIGURATOR_ROLE, pauser, 0);

    adapter = new EquityMultiplierAdapter(
      IEquityMultiplierAdapter.EquityMultiplierAdapterParams({
        aclManager: AaveV3Base.ACL_MANAGER,
        baseAggregatorAddress: MAG7_SPOKE_GOOGLc_PRICE_FEED,
        registry: address(REGISTRY),
        token: GOOGLc,
        spoke: MAG7_SPOKE,
        reserveId: GOOGLc_RESERVE_ID,
        pairDescription: 'GOOGLc / USD',
        minimumSnapshotDelay: 0,
        maximumLowerBoundDuration: 3 days,
        maximumYearlyRatioGrowthPercent: 10_00,
        priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
          snapshotRatio: uint104(liveMultiplier),
          snapshotTimestamp: uint48(block.timestamp - 73 days),
          maxYearlyRatioGrowthPercent: 5_00
        })
      })
    );

    vm.prank(MAG7_SPOKE);
    MAG7_SPOKE_ORACLE.setReserveSource(GOOGLc_RESERVE_ID, address(adapter));
  }

  function _mockMultiplier(uint256 multiplier) internal {
    vm.mockCall(GOOGLc, abi.encodeWithSelector(B20_MULTIPLIER_SELECTOR), abi.encode(multiplier));
  }

  function _price(uint256 base, uint256 multiplier) internal pure returns (uint256) {
    return (base * multiplier) / 1e18;
  }

  function _setCap(uint256 snapshotRatio) internal {
    vm.prank(boundsAgent);
    adapter.setCapParameters(
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: uint104(snapshotRatio),
        snapshotTimestamp: uint48(block.timestamp - 1 days),
        maxYearlyRatioGrowthPercent: 5_00
      })
    );
  }

  function _setPaused(bool paused) internal {
    vm.prank(pauser);
    SPOKE_CONFIGURATOR.updatePaused(MAG7_SPOKE, GOOGLc_RESERVE_ID, paused);
  }

  function test_liveRegistry() public view {
    assertGt(liveMultiplier, 1e18);
    assertFalse(livePaused);

    (uint256 multiplier, bool paused) = REGISTRY.getOracleParams(GOOGLc);
    assertEq(multiplier, liveMultiplier);
    assertEq(paused, livePaused);
    assertEq(adapter.getRatio(), int256(liveMultiplier));
    assertFalse(adapter.isReservePaused());
    assertFalse(adapter.isBreached());

    assertEq(adapter.latestAnswer(), int256(_price(basePrice, liveMultiplier)));
    assertEq(
      MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID),
      _price(basePrice, liveMultiplier)
    );
  }

  function test_dividendThenUnannouncedChange() public {
    uint256 dividend = (liveMultiplier * 1_0003) / 1_0000;
    _mockMultiplier(dividend);
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID), _price(basePrice, dividend));
    assertFalse(adapter.isBreached());

    _setCap(dividend);
    assertEq(adapter.getSnapshotRatio(), dividend);

    _mockMultiplier((liveMultiplier * 105) / 100);
    uint256 maxRatio = adapter.getMaxRatio();
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID), _price(basePrice, maxRatio));
    assertTrue(adapter.isBreached());

    _mockMultiplier(liveMultiplier);
    assertEq(
      MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID),
      _price(basePrice, liveMultiplier)
    );
    assertTrue(adapter.isBreached());
  }

  function test_splitOnlyWhilePaused() public {
    uint256 split = liveMultiplier * 2;
    _mockMultiplier(split);
    vm.mockCall(
      MAG7_SPOKE_GOOGLc_PRICE_FEED,
      abi.encodeWithSelector(IChainlinkAggregator.latestAnswer.selector),
      abi.encode(int256(basePrice / 2))
    );
    assertTrue(adapter.isBreached());

    vm.expectPartialRevert(IEquityMultiplierAdapter.MaxRatioIncrease.selector);
    _setCap(split);

    _setPaused(true);
    assertTrue(adapter.isReservePaused());
    _setCap(split);
    _setPaused(false);
    assertFalse(adapter.isReservePaused());

    assertFalse(adapter.isBreached());
    assertEq(MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID), _price(basePrice / 2, split));
  }

  function test_reverseSplitPricedAtRawWhilePaused() public {
    uint256 reverseSplit = liveMultiplier / 10;
    _mockMultiplier(reverseSplit);
    vm.mockCall(
      MAG7_SPOKE_GOOGLc_PRICE_FEED,
      abi.encodeWithSelector(IChainlinkAggregator.latestAnswer.selector),
      abi.encode(int256(basePrice * 10))
    );
    assertTrue(adapter.isBreached());

    _setPaused(true);
    assertEq(
      MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID),
      _price(basePrice * 10, reverseSplit)
    );
    _setCap(reverseSplit);
    _setPaused(false);

    assertFalse(adapter.isBreached());
    assertEq(
      MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID),
      _price(basePrice * 10, reverseSplit)
    );
  }

  function test_registryFailureRecovery() public {
    vm.mockCallRevert(GOOGLc, abi.encodeWithSelector(B20_MULTIPLIER_SELECTOR), '');
    assertTrue(adapter.isBreached());
    vm.expectRevert();
    MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID);

    vm.prank(boundsAgent);
    adapter.setLowerBound(uint104(liveMultiplier), uint48(block.timestamp + 1 days));
    assertEq(
      MAG7_SPOKE_ORACLE.getReservePrice(GOOGLc_RESERVE_ID),
      _price(basePrice, liveMultiplier)
    );
  }
}
