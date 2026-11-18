// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRateModel} from '../interfaces/IRateModel.sol';

contract FixedRateModel is IRateModel {
	uint256 public rate;

	constructor(uint256 rate_) {
		rate = rate_;
	}

	function setRate(uint256 rate_) external {
		rate = rate_;
	}

	function borrowRate(uint256, uint256) external view returns (uint256) {
		return rate;
	}
}
