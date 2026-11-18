// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {KinkRateModel} from '../contracts/rate/KinkRateModel.sol';

contract KinkRateModelTest is Test {
	KinkRateModel internal model;

	function setUp() public {
		// 2% base, +8% up to 90% utilization, +100% from there to full
		model = new KinkRateModel(0.02e18, 0.08e18, 1e18, 0.9e18);
	}

	function testRejectsInvalidKink() public {
		vm.expectRevert(KinkRateModel.InvalidKink.selector);
		new KinkRateModel(0, 0, 0, 0);
		vm.expectRevert(KinkRateModel.InvalidKink.selector);
		new KinkRateModel(0, 0, 0, 1e18);
	}

	function testRateAtPoints() public view {
		assertEq(model.borrowRate(100, 0), model.baseRate());
		_assertYearly(model.borrowRate(100, 45), 0.06e18);
		_assertYearly(model.borrowRate(100, 90), 0.1e18);
		_assertYearly(model.borrowRate(100, 100), 1.1e18);
	}

	function testUtilizationCapsAtOne() public view {
		assertEq(model.utilizationOf(100, 200), 1e18);
		assertEq(model.utilizationOf(0, 0), 0);
	}

	function testFuzzRateIsMonotonic(uint256 supplyAssets, uint256 a, uint256 b) public view {
		supplyAssets = bound(supplyAssets, 1, 1e30);
		a = bound(a, 0, supplyAssets);
		b = bound(b, a, supplyAssets);
		assertLe(model.borrowRate(supplyAssets, a), model.borrowRate(supplyAssets, b));
	}

	// Converting yearly rates to per second loses up to one wei per second per term
	function _assertYearly(uint256 perSecond, uint256 yearly) internal pure {
		assertApproxEqAbs(perSecond * 365 days, yearly, 3 * 365 days);
	}
}
