// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOracle {
	/// @notice Price of one raw unit of collateral in raw units of the loan token, scaled by 1e36
	function price() external view returns (uint256);
}
