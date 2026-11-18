// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Base} from './Base.sol';
import {Lend} from '../contracts/Lend.sol';
import {ILend, MarketConfig, MarketState, Position} from '../contracts/interfaces/ILend.sol';

contract LendTest is Base {
	/******************************************************************************/
	/*** Admin                                                                  ***/
	/******************************************************************************/

	function testInitializeOnlyOnce() public {
		vm.expectRevert();
		lend.initialize(admin, riskManager, feeRecipient);
	}

	function testCreateMarketOnlyRiskManager() public {
		MarketConfig memory config = defaultConfig();
		vm.expectRevert(
			abi.encodeWithSelector(
				IAccessControl.AccessControlUnauthorizedAccount.selector,
				address(this),
				lend.RISK_MANAGER()
			)
		);
		lend.createMarket(config);
	}

	function testCreateMarketRejectsInvalidConfig() public {
		MarketConfig memory config = defaultConfig();
		config.maxLtv = 0.9e18;
		_expectInvalid(config);

		config = defaultConfig();
		config.liquidationLtv = 1e18;
		_expectInvalid(config);

		config = defaultConfig();
		config.collateralToken = config.loanToken;
		_expectInvalid(config);

		config = defaultConfig();
		config.maxLtv = 0;
		_expectInvalid(config);

		config = defaultConfig();
		config.reserveFactor = 0.6e18;
		_expectInvalid(config);
	}

	function testUnknownMarketReverts() public {
		vm.expectRevert(ILend.UnknownMarket.selector);
		vm.prank(supplier);
		lend.supply(id + 1, 1e6, supplier);
	}

	function testUpgradeOnlyAdmin() public {
		Lend next = new Lend();
		vm.expectRevert();
		lend.upgradeToAndCall(address(next), '');

		vm.prank(admin);
		lend.upgradeToAndCall(address(next), '');
	}

	/******************************************************************************/
	/*** Supply and withdraw                                                    ***/
	/******************************************************************************/

	function testSupplyAndRedeem() public {
		uint256 shares = _supply(supplier, 1000e6);
		assertEq(lend.position(id, supplier).supplyShares, shares);
		assertEq(loan.balanceOf(address(lend)), 1000e6);

		vm.prank(supplier);
		uint256 assets = lend.redeem(id, shares, supplier, supplier);
		assertEq(assets, 1000e6);
		assertEq(lend.position(id, supplier).supplyShares, 0);
	}

	function testWithdrawByAssets() public {
		_supply(supplier, 1000e6);
		vm.prank(supplier);
		lend.withdraw(id, 400e6, supplier, supplier);
		assertEq(lend.marketState(id).totalSupplyAssets, 600e6);
	}

	function testCannotWithdrawBorrowedLiquidity() public {
		_supply(supplier, 1000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 800e6);

		vm.expectRevert(ILend.InsufficientLiquidity.selector);
		vm.prank(supplier);
		lend.withdraw(id, 300e6, supplier, supplier);
	}

	function testCannotWithdrawOthersSupply() public {
		_supply(supplier, 1000e6);
		vm.expectRevert(ILend.Unauthorized.selector);
		vm.prank(borrower);
		lend.withdraw(id, 1e6, supplier, borrower);
	}

	/******************************************************************************/
	/*** Borrow and repay                                                       ***/
	/******************************************************************************/

	function testBorrowUpToMaxLtv() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 1600e6);
		assertEq(loan.balanceOf(borrower), 1e30 + 1600e6);

		vm.expectRevert(ILend.InsufficientCollateral.selector);
		_borrow(borrower, 1);
	}

	function testBorrowWithoutCollateralReverts() public {
		_supply(supplier, 10_000e6);
		vm.expectRevert(ILend.InsufficientCollateral.selector);
		_borrow(borrower, 1e6);
	}

	function testWithdrawCollateralChecksLtv() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 2e18);
		_borrow(borrower, 1600e6);

		vm.prank(borrower);
		lend.withdrawCollateral(id, 1e18, borrower, borrower);

		vm.expectRevert(ILend.InsufficientCollateral.selector);
		vm.prank(borrower);
		lend.withdrawCollateral(id, 1, borrower, borrower);
	}

	function testRepaySharesClearsDebt() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		uint256 shares = _borrow(borrower, 1000e6);
		vm.warp(block.timestamp + 30 days);

		uint256 before = loan.balanceOf(borrower);
		vm.prank(borrower);
		uint256 repaid = lend.repayShares(id, shares, borrower);
		assertGt(repaid, 1000e6);
		assertEq(before - loan.balanceOf(borrower), repaid);
		assertEq(lend.position(id, borrower).borrowShares, 0);
		assertEq(lend.marketState(id).totalBorrowAssets, 0);

		vm.prank(borrower);
		lend.withdrawCollateral(id, 1e18, borrower, borrower);
	}

	function testRepayMoreThanDebtReverts() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 1000e6);

		vm.expectRevert(ILend.InsufficientBalance.selector);
		vm.prank(borrower);
		lend.repay(id, 2000e6, borrower);
	}

	function testAnyoneCanRepayForBorrower() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 1000e6);

		vm.prank(supplier);
		lend.repay(id, 500e6, borrower);
		assertApproxEqAbs(lend.marketState(id).totalBorrowAssets, 500e6, 1);
	}

	/******************************************************************************/
	/*** Interest                                                               ***/
	/******************************************************************************/

	function testInterestCompoundsAndPaysFee() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 1000e6);
		vm.warp(block.timestamp + 365 days);
		lend.accrueInterest(id);

		MarketState memory state = lend.marketState(id);
		// e^0.1 - 1 = 0.10517, the third-order expansion gives 0.10516
		uint256 interest = state.totalBorrowAssets - 1000e6;
		assertApproxEqRel(interest, 105.17e6, 0.001e18);
		assertEq(state.totalSupplyAssets, 10_000e6 + interest);

		Position memory fees = lend.position(id, feeRecipient);
		uint256 feeAssets = (uint256(fees.supplyShares) * state.totalSupplyAssets) / state.totalSupplyShares;
		assertApproxEqAbs(feeAssets, interest / 10, 1);
	}

	function testNoInterestWithoutBorrows() public {
		_supply(supplier, 10_000e6);
		vm.warp(block.timestamp + 365 days);
		lend.accrueInterest(id);
		assertEq(lend.marketState(id).totalSupplyAssets, 10_000e6);
	}

	function testRateModelChangeAccruesAtOldRate() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 1000e6);
		vm.warp(block.timestamp + 365 days);

		vm.prank(riskManager);
		lend.setRateModel(id, rateModel);
		assertApproxEqRel(lend.marketState(id).totalBorrowAssets, 1105.17e6, 0.001e18);
	}

	function testHealthDropsWithPrice() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		_borrow(borrower, 1600e6);
		assertTrue(lend.isHealthy(id, borrower));

		// 1600 / 0.85 = 1882.35, below that the position is past the liquidation LTV
		oracle.setPrice(1880e6 * 1e36 / 1e18);
		assertFalse(lend.isHealthy(id, borrower));
	}

	/******************************************************************************/
	/*** Caps, pause, operators                                                 ***/
	/******************************************************************************/

	function testSupplyCap() public {
		vm.prank(riskManager);
		lend.setCaps(id, 1000e6, type(uint128).max);
		_supply(supplier, 1000e6);

		vm.expectRevert(ILend.SupplyCapExceeded.selector);
		_supply(supplier, 1);
	}

	function testBorrowCap() public {
		vm.prank(riskManager);
		lend.setCaps(id, type(uint128).max, 100e6);
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);

		vm.expectRevert(ILend.BorrowCapExceeded.selector);
		_borrow(borrower, 101e6);
	}

	function testPauseBlocksSupplyAndBorrowButNotExit() public {
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);
		uint256 shares = _borrow(borrower, 100e6);

		vm.prank(riskManager);
		lend.setPaused(id, true, true);

		vm.expectRevert(ILend.SupplyPaused.selector);
		_supply(supplier, 1e6);
		vm.expectRevert(ILend.BorrowPaused.selector);
		_borrow(borrower, 1e6);

		vm.prank(borrower);
		lend.repayShares(id, shares, borrower);
		vm.prank(supplier);
		lend.withdraw(id, 1000e6, supplier, supplier);
	}

	function testOperatorCanBorrowForOwner() public {
		address operator = makeAddr('operator');
		_supply(supplier, 10_000e6);
		_supplyCollateral(borrower, 1e18);

		vm.expectRevert(ILend.Unauthorized.selector);
		vm.prank(operator);
		lend.borrow(id, 100e6, borrower, operator);

		vm.prank(borrower);
		lend.setOperator(operator, true);
		vm.prank(operator);
		lend.borrow(id, 100e6, borrower, operator);
		assertEq(loan.balanceOf(operator), 100e6);
	}

	/******************************************************************************/
	/*** Fuzz                                                                   ***/
	/******************************************************************************/

	function testFuzzSupplyRedeemNeverProfits(uint256 first, uint256 second) public {
		first = bound(first, 1, 1e24);
		second = bound(second, 1, 1e24);
		address other = makeAddr('other');
		_fund(other);

		_supply(supplier, first);
		uint256 shares = _supply(other, second);

		vm.prank(other);
		uint256 assets = lend.redeem(id, shares, other, other);
		assertLe(assets, second);
	}

	function testFuzzBorrowRepayNeverUnderpays(uint256 assets, uint256 elapsed) public {
		assets = bound(assets, 1, 1600e6);
		elapsed = bound(elapsed, 0, 10 * 365 days);
		_supply(supplier, 1_000_000e6);
		_supplyCollateral(borrower, 1e18);
		uint256 shares = _borrow(borrower, assets);
		vm.warp(block.timestamp + elapsed);

		vm.prank(borrower);
		uint256 repaid = lend.repayShares(id, shares, borrower);
		assertGe(repaid, assets);
	}

	function _expectInvalid(MarketConfig memory config) internal {
		vm.expectRevert(ILend.InvalidConfig.selector);
		vm.prank(riskManager);
		lend.createMarket(config);
	}
}
