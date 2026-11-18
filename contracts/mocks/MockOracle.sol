// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from '../interfaces/IOracle.sol';

contract MockOracle is IOracle {
	uint256 public price;

	constructor(uint256 price_) {
		price = price_;
	}

	function setPrice(uint256 price_) external {
		price = price_;
	}
}
