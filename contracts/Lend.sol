// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {ILend, MarketConfig, MarketState, Position} from './interfaces/ILend.sol';
import {IRateModel} from './interfaces/IRateModel.sol';

/**
 * Isolated lending markets with one loan token and one collateral token each. Markets are
 * created by the risk manager. Tokens must be plain ERC-20s: fee-on-transfer and rebasing tokens
 * break the accounting, so they must never be listed
 **/
contract Lend is ILend, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
	using SafeERC20 for IERC20;
	using SafeCast for uint256;
	using Math for uint256;

	bytes32 public constant RISK_MANAGER = keccak256('RISK_MANAGER');

	uint256 internal constant WAD = 1e18;
	uint256 internal constant ORACLE_SCALE = 1e36;
	uint256 internal constant MAX_RESERVE_FACTOR = 0.5e18;
	// Virtual shares and assets stop the first depositor from inflating the share price
	uint256 internal constant VIRTUAL_SHARES = 1e6;
	uint256 internal constant VIRTUAL_ASSETS = 1;

	uint256 public marketCount;
	address public feeRecipient;
	mapping(address owner => mapping(address operator => bool)) public isOperator;
	mapping(uint256 id => MarketConfig) internal _configs;
	mapping(uint256 id => MarketState) internal _states;
	mapping(uint256 id => mapping(address user => Position)) internal _positions;

	/// @custom:oz-upgrades-unsafe-allow constructor
	constructor() {
		_disableInitializers();
	}

	function initialize(address admin, address riskManager, address feeRecipient_) external initializer {
		if (admin == address(0) || riskManager == address(0) || feeRecipient_ == address(0)) {
			revert ZeroAddress();
		}

		__AccessControl_init();
		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(RISK_MANAGER, riskManager);
		feeRecipient = feeRecipient_;
		emit FeeRecipientSet(feeRecipient_);
	}

	function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

	/******************************************************************************/
	/*** Admin                                                                  ***/
	/******************************************************************************/

	function createMarket(MarketConfig calldata config) external onlyRole(RISK_MANAGER) returns (uint256 id) {
		if (
			config.loanToken == address(0) ||
			config.collateralToken == address(0) ||
			config.loanToken == config.collateralToken ||
			address(config.oracle) == address(0) ||
			address(config.rateModel) == address(0) ||
			config.maxLtv == 0 ||
			config.maxLtv > config.liquidationLtv ||
			config.liquidationLtv >= WAD ||
			config.reserveFactor > MAX_RESERVE_FACTOR
		) {
			revert InvalidConfig();
		}

		id = marketCount++;
		_configs[id] = config;
		_states[id].lastAccrual = uint64(block.timestamp);
		emit MarketCreated(id, config);
	}

	function setCaps(uint256 id, uint128 supplyCap, uint128 borrowCap) external onlyRole(RISK_MANAGER) {
		_requireMarket(id);
		_configs[id].supplyCap = supplyCap;
		_configs[id].borrowCap = borrowCap;
		emit CapsSet(id, supplyCap, borrowCap);
	}

	function setPaused(uint256 id, bool supplyPaused, bool borrowPaused) external onlyRole(RISK_MANAGER) {
		_requireMarket(id);
		_configs[id].supplyPaused = supplyPaused;
		_configs[id].borrowPaused = borrowPaused;
		emit PausedSet(id, supplyPaused, borrowPaused);
	}

	function setReserveFactor(uint256 id, uint64 reserveFactor) external onlyRole(RISK_MANAGER) {
		_requireMarket(id);
		if (reserveFactor > MAX_RESERVE_FACTOR) {
			revert InvalidConfig();
		}

		_accrue(id);
		_configs[id].reserveFactor = reserveFactor;
		emit ReserveFactorSet(id, reserveFactor);
	}

	function setRateModel(uint256 id, IRateModel rateModel) external onlyRole(RISK_MANAGER) {
		_requireMarket(id);
		if (address(rateModel) == address(0)) {
			revert InvalidConfig();
		}

		// Interest up to now is charged at the old rate
		_accrue(id);
		_configs[id].rateModel = rateModel;
		emit RateModelSet(id, rateModel);
	}

	function setFeeRecipient(address feeRecipient_) external onlyRole(DEFAULT_ADMIN_ROLE) {
		if (feeRecipient_ == address(0)) {
			revert ZeroAddress();
		}

		feeRecipient = feeRecipient_;
		emit FeeRecipientSet(feeRecipient_);
	}

	function setOperator(address operator, bool approved) external {
		isOperator[msg.sender][operator] = approved;
		emit OperatorSet(msg.sender, operator, approved);
	}

	/******************************************************************************/
	/*** Lending                                                                ***/
	/******************************************************************************/

	function accrueInterest(uint256 id) external nonReentrant {
		_requireMarket(id);
		_accrue(id);
	}

	function supply(uint256 id, uint256 assets, address onBehalf) external nonReentrant returns (uint256 shares) {
		_requireMarket(id);
		_requireNonZero(assets, onBehalf);
		MarketConfig storage config = _configs[id];
		if (config.supplyPaused) {
			revert SupplyPaused();
		}

		_accrue(id);
		MarketState storage state = _states[id];
		if (state.totalSupplyAssets + assets > config.supplyCap) {
			revert SupplyCapExceeded();
		}

		shares = _toShares(assets, state.totalSupplyAssets, state.totalSupplyShares, Math.Rounding.Floor);
		if (shares == 0) {
			revert ZeroAmount();
		}

		_positions[id][onBehalf].supplyShares += shares.toUint128();
		state.totalSupplyShares += shares.toUint128();
		state.totalSupplyAssets += assets.toUint128();
		emit Supply(id, msg.sender, onBehalf, assets, shares);

		IERC20(config.loanToken).safeTransferFrom(msg.sender, address(this), assets);
	}

	function withdraw(
		uint256 id,
		uint256 assets,
		address owner,
		address receiver
	) external nonReentrant returns (uint256 shares) {
		_requireMarket(id);
		_requireNonZero(assets, receiver);
		_requireAuthorized(owner);
		_accrue(id);
		MarketState storage state = _states[id];
		shares = _toShares(assets, state.totalSupplyAssets, state.totalSupplyShares, Math.Rounding.Ceil);
		_withdraw(id, assets, shares, owner, receiver);
	}

	function redeem(
		uint256 id,
		uint256 shares,
		address owner,
		address receiver
	) external nonReentrant returns (uint256 assets) {
		_requireMarket(id);
		_requireNonZero(shares, receiver);
		_requireAuthorized(owner);
		_accrue(id);
		MarketState storage state = _states[id];
		assets = _toAssets(shares, state.totalSupplyAssets, state.totalSupplyShares, Math.Rounding.Floor);
		if (assets == 0) {
			revert ZeroAmount();
		}

		_withdraw(id, assets, shares, owner, receiver);
	}

	function supplyCollateral(uint256 id, uint256 assets, address onBehalf) external nonReentrant {
		_requireMarket(id);
		_requireNonZero(assets, onBehalf);
		_positions[id][onBehalf].collateral += assets.toUint128();
		_states[id].totalCollateral += assets.toUint128();
		emit SupplyCollateral(id, msg.sender, onBehalf, assets);

		IERC20(_configs[id].collateralToken).safeTransferFrom(msg.sender, address(this), assets);
	}

	function withdrawCollateral(uint256 id, uint256 assets, address owner, address receiver) external nonReentrant {
		_requireMarket(id);
		_requireNonZero(assets, receiver);
		_requireAuthorized(owner);
		_accrue(id);
		Position storage pos = _positions[id][owner];
		if (assets > pos.collateral) {
			revert InsufficientBalance();
		}

		pos.collateral -= assets.toUint128();
		_states[id].totalCollateral -= assets.toUint128();
		if (!_withinLtv(id, owner, _configs[id].maxLtv)) {
			revert InsufficientCollateral();
		}

		emit WithdrawCollateral(id, msg.sender, owner, receiver, assets);

		IERC20(_configs[id].collateralToken).safeTransfer(receiver, assets);
	}

	function borrow(
		uint256 id,
		uint256 assets,
		address owner,
		address receiver
	) external nonReentrant returns (uint256 shares) {
		_requireMarket(id);
		_requireNonZero(assets, receiver);
		_requireAuthorized(owner);
		MarketConfig storage config = _configs[id];
		if (config.borrowPaused) {
			revert BorrowPaused();
		}

		_accrue(id);
		MarketState storage state = _states[id];
		if (state.totalBorrowAssets + assets > config.borrowCap) {
			revert BorrowCapExceeded();
		}

		shares = _toShares(assets, state.totalBorrowAssets, state.totalBorrowShares, Math.Rounding.Ceil);
		_positions[id][owner].borrowShares += shares.toUint128();
		state.totalBorrowShares += shares.toUint128();
		state.totalBorrowAssets += assets.toUint128();
		if (state.totalBorrowAssets > state.totalSupplyAssets) {
			revert InsufficientLiquidity();
		}

		if (!_withinLtv(id, owner, config.maxLtv)) {
			revert InsufficientCollateral();
		}

		emit Borrow(id, msg.sender, owner, receiver, assets, shares);

		IERC20(config.loanToken).safeTransfer(receiver, assets);
	}

	function repay(uint256 id, uint256 assets, address onBehalf) external nonReentrant returns (uint256 shares) {
		_requireMarket(id);
		_requireNonZero(assets, onBehalf);
		_accrue(id);
		MarketState storage state = _states[id];
		shares = _toShares(assets, state.totalBorrowAssets, state.totalBorrowShares, Math.Rounding.Floor);
		if (shares == 0) {
			revert ZeroAmount();
		}

		_repay(id, assets, shares, onBehalf);
	}

	function repayShares(uint256 id, uint256 shares, address onBehalf) external nonReentrant returns (uint256 assets) {
		_requireMarket(id);
		_requireNonZero(shares, onBehalf);
		_accrue(id);
		MarketState storage state = _states[id];
		assets = _toAssets(shares, state.totalBorrowAssets, state.totalBorrowShares, Math.Rounding.Ceil);
		_repay(id, assets, shares, onBehalf);
	}

	/******************************************************************************/
	/*** Views                                                                  ***/
	/******************************************************************************/

	function marketConfig(uint256 id) external view returns (MarketConfig memory) {
		return _configs[id];
	}

	function marketState(uint256 id) external view returns (MarketState memory) {
		return _states[id];
	}

	function position(uint256 id, address user) external view returns (Position memory) {
		return _positions[id][user];
	}

	/// @notice Checks the position against the liquidation LTV using stored state, without pending interest
	function isHealthy(uint256 id, address user) external view returns (bool) {
		_requireMarket(id);
		return _withinLtv(id, user, _configs[id].liquidationLtv);
	}

	/******************************************************************************/
	/*** Internal                                                               ***/
	/******************************************************************************/

	function _withdraw(uint256 id, uint256 assets, uint256 shares, address owner, address receiver) internal {
		Position storage pos = _positions[id][owner];
		if (shares > pos.supplyShares) {
			revert InsufficientBalance();
		}

		MarketState storage state = _states[id];
		pos.supplyShares -= shares.toUint128();
		state.totalSupplyShares -= shares.toUint128();
		state.totalSupplyAssets -= assets.toUint128();
		if (state.totalBorrowAssets > state.totalSupplyAssets) {
			revert InsufficientLiquidity();
		}

		emit Withdraw(id, msg.sender, owner, receiver, assets, shares);

		IERC20(_configs[id].loanToken).safeTransfer(receiver, assets);
	}

	function _repay(uint256 id, uint256 assets, uint256 shares, address onBehalf) internal {
		Position storage pos = _positions[id][onBehalf];
		if (shares > pos.borrowShares) {
			revert InsufficientBalance();
		}

		MarketState storage state = _states[id];
		pos.borrowShares -= shares.toUint128();
		state.totalBorrowShares -= shares.toUint128();
		// Rounding up the last repayment can exceed the total by a few wei
		state.totalBorrowAssets = assets >= state.totalBorrowAssets
			? 0
			: state.totalBorrowAssets - assets.toUint128();
		emit Repay(id, msg.sender, onBehalf, assets, shares);

		IERC20(_configs[id].loanToken).safeTransferFrom(msg.sender, address(this), assets);
	}

	function _accrue(uint256 id) internal {
		MarketState storage state = _states[id];
		uint256 elapsed = block.timestamp - state.lastAccrual;
		if (elapsed == 0) {
			return;
		}

		state.lastAccrual = uint64(block.timestamp);
		if (state.totalBorrowAssets == 0) {
			return;
		}

		MarketConfig storage config = _configs[id];
		uint256 rate = config.rateModel.borrowRate(state.totalSupplyAssets, state.totalBorrowAssets);
		uint256 interest = uint256(state.totalBorrowAssets).mulDiv(_compound(rate * elapsed), WAD);
		state.totalBorrowAssets += interest.toUint128();
		state.totalSupplyAssets += interest.toUint128();

		uint256 feeShares;
		if (config.reserveFactor != 0) {
			uint256 fee = interest.mulDiv(config.reserveFactor, WAD);
			feeShares = _toShares(
				fee,
				state.totalSupplyAssets - fee,
				state.totalSupplyShares,
				Math.Rounding.Floor
			);
			_positions[id][feeRecipient].supplyShares += feeShares.toUint128();
			state.totalSupplyShares += feeShares.toUint128();
		}

		emit InterestAccrued(id, rate, interest, feeShares);
	}

	// e^x - 1 to the third term, so interest compounds over the period since the last accrual
	function _compound(uint256 x) internal pure returns (uint256) {
		uint256 second = x.mulDiv(x, 2 * WAD);
		uint256 third = second.mulDiv(x, 3 * WAD);
		return x + second + third;
	}

	function _withinLtv(uint256 id, address user, uint256 ltv) internal view returns (bool) {
		Position storage pos = _positions[id][user];
		if (pos.borrowShares == 0) {
			return true;
		}

		MarketState storage state = _states[id];
		uint256 borrowed = _toAssets(
			pos.borrowShares,
			state.totalBorrowAssets,
			state.totalBorrowShares,
			Math.Rounding.Ceil
		);
		uint256 collateralValue = uint256(pos.collateral).mulDiv(_configs[id].oracle.price(), ORACLE_SCALE);
		return borrowed <= collateralValue.mulDiv(ltv, WAD);
	}

	function _toShares(
		uint256 assets,
		uint256 totalAssets,
		uint256 totalShares,
		Math.Rounding rounding
	) internal pure returns (uint256) {
		return assets.mulDiv(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, rounding);
	}

	function _toAssets(
		uint256 shares,
		uint256 totalAssets,
		uint256 totalShares,
		Math.Rounding rounding
	) internal pure returns (uint256) {
		return shares.mulDiv(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, rounding);
	}

	function _requireMarket(uint256 id) internal view {
		if (id >= marketCount) {
			revert UnknownMarket();
		}
	}

	function _requireNonZero(uint256 amount, address account) internal pure {
		if (amount == 0) {
			revert ZeroAmount();
		}

		if (account == address(0)) {
			revert ZeroAddress();
		}
	}

	function _requireAuthorized(address owner) internal view {
		if (msg.sender != owner && !isOperator[owner][msg.sender]) {
			revert Unauthorized();
		}
	}
}
