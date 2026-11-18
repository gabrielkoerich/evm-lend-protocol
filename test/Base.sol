// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Lend} from '../contracts/Lend.sol';
import {MarketConfig} from '../contracts/interfaces/ILend.sol';
import {IOracle} from '../contracts/interfaces/IOracle.sol';
import {IRateModel} from '../contracts/interfaces/IRateModel.sol';
import {MockERC20} from '../contracts/mocks/MockERC20.sol';
import {MockOracle} from '../contracts/mocks/MockOracle.sol';
import {FixedRateModel} from '../contracts/mocks/FixedRateModel.sol';

contract Base is Test {
	// 2000 loan units (6 decimals) per collateral unit (18 decimals)
	uint256 internal constant PRICE = 2000e6 * 1e36 / 1e18;
	uint256 internal constant RATE = uint256(0.1e18) / 365 days;

	address internal admin = makeAddr('admin');
	address internal riskManager = makeAddr('riskManager');
	address internal feeRecipient = makeAddr('feeRecipient');
	address internal supplier = makeAddr('supplier');
	address internal borrower = makeAddr('borrower');

	Lend internal lend;
	MockERC20 internal loan;
	MockERC20 internal collateral;
	MockOracle internal oracle;
	FixedRateModel internal rateModel;
	uint256 internal id;

	function setUp() public virtual {
		loan = new MockERC20('Loan', 'LOAN', 6);
		collateral = new MockERC20('Collateral', 'COLL', 18);
		oracle = new MockOracle(PRICE);
		rateModel = new FixedRateModel(RATE);

		Lend implementation = new Lend();
		bytes memory init = abi.encodeCall(Lend.initialize, (admin, riskManager, feeRecipient));
		lend = Lend(address(new ERC1967Proxy(address(implementation), init)));

		vm.prank(riskManager);
		id = lend.createMarket(defaultConfig());

		_fund(supplier);
		_fund(borrower);
	}

	function defaultConfig() internal view returns (MarketConfig memory) {
		return
			MarketConfig({
				loanToken: address(loan),
				collateralToken: address(collateral),
				oracle: IOracle(address(oracle)),
				rateModel: IRateModel(address(rateModel)),
				maxLtv: 0.8e18,
				liquidationLtv: 0.85e18,
				reserveFactor: 0.1e18,
				supplyPaused: false,
				borrowPaused: false,
				supplyCap: type(uint128).max,
				borrowCap: type(uint128).max
			});
	}

	function _fund(address user) internal {
		loan.mint(user, 1e30);
		collateral.mint(user, 1e30);
		vm.startPrank(user);
		loan.approve(address(lend), type(uint256).max);
		collateral.approve(address(lend), type(uint256).max);
		vm.stopPrank();
	}

	function _supply(address user, uint256 assets) internal returns (uint256) {
		vm.prank(user);
		return lend.supply(id, assets, user);
	}

	function _supplyCollateral(address user, uint256 assets) internal {
		vm.prank(user);
		lend.supplyCollateral(id, assets, user);
	}

	function _borrow(address user, uint256 assets) internal returns (uint256) {
		vm.prank(user);
		return lend.borrow(id, assets, user, user);
	}
}
