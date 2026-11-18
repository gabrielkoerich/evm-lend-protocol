// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRateModel {
	/// @notice Borrow rate per second, scaled by 1e18
	function borrowRate(uint256 supplyAssets, uint256 borrowAssets) external view returns (uint256);
}
