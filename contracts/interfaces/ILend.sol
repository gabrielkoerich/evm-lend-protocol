// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from './IOracle.sol';
import {IRateModel} from './IRateModel.sol';

struct MarketConfig {
	address loanToken;
	address collateralToken;
	IOracle oracle;
	IRateModel rateModel;
	// LTVs and reserve factor are scaled by 1e18
	uint64 maxLtv;
	uint64 liquidationLtv;
	uint64 reserveFactor;
	bool supplyPaused;
	bool borrowPaused;
	uint128 supplyCap;
	uint128 borrowCap;
}

struct MarketState {
	uint128 totalSupplyAssets;
	uint128 totalSupplyShares;
	uint128 totalBorrowAssets;
	uint128 totalBorrowShares;
	uint128 totalCollateral;
	uint64 lastAccrual;
}

struct Position {
	uint128 supplyShares;
	uint128 borrowShares;
	uint128 collateral;
}

interface ILend {
	event MarketCreated(uint256 indexed id, MarketConfig config);
	event CapsSet(uint256 indexed id, uint128 supplyCap, uint128 borrowCap);
	event PausedSet(uint256 indexed id, bool supplyPaused, bool borrowPaused);
	event ReserveFactorSet(uint256 indexed id, uint64 reserveFactor);
	event RateModelSet(uint256 indexed id, IRateModel rateModel);
	event FeeRecipientSet(address feeRecipient);
	event OperatorSet(address indexed owner, address indexed operator, bool approved);

	event InterestAccrued(uint256 indexed id, uint256 rate, uint256 interest, uint256 feeShares);
	event Supply(uint256 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
	event Withdraw(
		uint256 indexed id,
		address caller,
		address indexed owner,
		address indexed receiver,
		uint256 assets,
		uint256 shares
	);
	event SupplyCollateral(uint256 indexed id, address indexed caller, address indexed onBehalf, uint256 assets);
	event WithdrawCollateral(
		uint256 indexed id,
		address caller,
		address indexed owner,
		address indexed receiver,
		uint256 assets
	);
	event Borrow(
		uint256 indexed id,
		address caller,
		address indexed owner,
		address indexed receiver,
		uint256 assets,
		uint256 shares
	);
	event Repay(uint256 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);

	error InvalidConfig();
	error UnknownMarket();
	error ZeroAmount();
	error ZeroAddress();
	error SupplyPaused();
	error BorrowPaused();
	error SupplyCapExceeded();
	error BorrowCapExceeded();
	error InsufficientBalance();
	error InsufficientLiquidity();
	error InsufficientCollateral();
	error Unauthorized();

	function createMarket(MarketConfig calldata config) external returns (uint256 id);
	function setCaps(uint256 id, uint128 supplyCap, uint128 borrowCap) external;
	function setPaused(uint256 id, bool supplyPaused, bool borrowPaused) external;
	function setReserveFactor(uint256 id, uint64 reserveFactor) external;
	function setRateModel(uint256 id, IRateModel rateModel) external;
	function setFeeRecipient(address feeRecipient) external;
	function setOperator(address operator, bool approved) external;

	function accrueInterest(uint256 id) external;
	function supply(uint256 id, uint256 assets, address onBehalf) external returns (uint256 shares);
	function withdraw(uint256 id, uint256 assets, address owner, address receiver) external returns (uint256 shares);
	function redeem(uint256 id, uint256 shares, address owner, address receiver) external returns (uint256 assets);
	function supplyCollateral(uint256 id, uint256 assets, address onBehalf) external;
	function withdrawCollateral(uint256 id, uint256 assets, address owner, address receiver) external;
	function borrow(uint256 id, uint256 assets, address owner, address receiver) external returns (uint256 shares);
	function repay(uint256 id, uint256 assets, address onBehalf) external returns (uint256 shares);
	function repayShares(uint256 id, uint256 shares, address onBehalf) external returns (uint256 assets);

	function marketCount() external view returns (uint256);
	function marketConfig(uint256 id) external view returns (MarketConfig memory);
	function marketState(uint256 id) external view returns (MarketState memory);
	function position(uint256 id, address user) external view returns (Position memory);
	function isOperator(address owner, address operator) external view returns (bool);
	function feeRecipient() external view returns (address);
	function isHealthy(uint256 id, address user) external view returns (bool);
}
