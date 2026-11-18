// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IRateModel} from '../interfaces/IRateModel.sol';

/// @notice Borrow rate rises linearly with utilization up to the kink, then on a steeper slope
contract KinkRateModel is IRateModel {
	using Math for uint256;

	uint256 internal constant WAD = 1e18;
	uint256 internal constant YEAR = 365 days;

	// Per second, scaled by 1e18
	uint256 public immutable baseRate;
	uint256 public immutable slope1;
	uint256 public immutable slope2;
	// Utilization scaled by 1e18
	uint256 public immutable kink;

	error InvalidKink();

	/// @param baseRateYear Rates are yearly and scaled by 1e18, so 0.04e18 is 4% a year
	constructor(uint256 baseRateYear, uint256 slope1Year, uint256 slope2Year, uint256 kink_) {
		if (kink_ == 0 || kink_ >= WAD) {
			revert InvalidKink();
		}

		baseRate = baseRateYear / YEAR;
		slope1 = slope1Year / YEAR;
		slope2 = slope2Year / YEAR;
		kink = kink_;
	}

	function borrowRate(uint256 supplyAssets, uint256 borrowAssets) external view returns (uint256) {
		uint256 utilization = utilizationOf(supplyAssets, borrowAssets);
		if (utilization <= kink) {
			return baseRate + slope1.mulDiv(utilization, kink);
		}

		return baseRate + slope1 + slope2.mulDiv(utilization - kink, WAD - kink);
	}

	function utilizationOf(uint256 supplyAssets, uint256 borrowAssets) public pure returns (uint256) {
		if (borrowAssets == 0) {
			return 0;
		}

		if (borrowAssets >= supplyAssets) {
			return WAD;
		}

		return borrowAssets.mulDiv(WAD, supplyAssets);
	}
}
