// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from 'forge-std/Base.sol';
import {StdCheats} from 'forge-std/StdCheats.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';
import {Base} from './Base.sol';
import {Lend} from '../contracts/Lend.sol';
import {MarketState} from '../contracts/interfaces/ILend.sol';
import {MockERC20} from '../contracts/mocks/MockERC20.sol';

contract Handler is CommonBase, StdCheats, StdUtils {
	Lend internal lend;
	MockERC20 internal loan;
	uint256 internal id;
	address[] public actors;

	constructor(Lend lend_, MockERC20 loan_, uint256 id_, address[] memory actors_) {
		lend = lend_;
		loan = loan_;
		id = id_;
		actors = actors_;
	}

	function supply(uint256 actor, uint256 assets) external {
		address user = _actor(actor);
		assets = bound(assets, 1, 1e15);
		vm.prank(user);
		lend.supply(id, assets, user);
	}

	function redeem(uint256 actor, uint256 shares) external {
		address user = _actor(actor);
		uint256 owned = lend.position(id, user).supplyShares;
		if (owned == 0) {
			return;
		}

		vm.prank(user);
		lend.redeem(id, bound(shares, 1, owned), user, user);
	}

	function supplyCollateral(uint256 actor, uint256 assets) external {
		address user = _actor(actor);
		vm.prank(user);
		lend.supplyCollateral(id, bound(assets, 1, 1e24), user);
	}

	function borrow(uint256 actor, uint256 assets) external {
		address user = _actor(actor);
		vm.prank(user);
		lend.borrow(id, bound(assets, 1, 1e13), user, user);
	}

	function repayShares(uint256 actor, uint256 shares) external {
		address user = _actor(actor);
		uint256 owed = lend.position(id, user).borrowShares;
		if (owed == 0) {
			return;
		}

		vm.prank(user);
		lend.repayShares(id, bound(shares, 1, owed), user);
	}

	function warp(uint256 seconds_) external {
		vm.warp(block.timestamp + bound(seconds_, 1, 30 days));
	}

	function actorCount() external view returns (uint256) {
		return actors.length;
	}

	function _actor(uint256 seed) internal view returns (address) {
		return actors[seed % actors.length];
	}
}

contract LendInvariantTest is Base {
	Handler internal handler;
	address[] internal actors;

	function setUp() public override {
		super.setUp();
		for (uint256 i = 0; i < 4; i++) {
			address actor = makeAddr(string(abi.encodePacked('actor', vm.toString(i))));
			_fund(actor);
			actors.push(actor);
		}

		handler = new Handler(lend, loan, id, actors);
		targetContract(address(handler));
	}

	function invariant_borrowsNeverExceedSupply() public view {
		MarketState memory state = lend.marketState(id);
		assertLe(state.totalBorrowAssets, state.totalSupplyAssets);
	}

	function invariant_cashCoversIdleSupply() public view {
		MarketState memory state = lend.marketState(id);
		assertGe(loan.balanceOf(address(lend)), state.totalSupplyAssets - state.totalBorrowAssets);
	}

	function invariant_collateralMatchesBalance() public view {
		assertEq(collateral.balanceOf(address(lend)), lend.marketState(id).totalCollateral);
	}

	function invariant_sharesSumToTotals() public view {
		MarketState memory state = lend.marketState(id);
		uint256 supplyShares = lend.position(id, feeRecipient).supplyShares;
		uint256 borrowShares;
		for (uint256 i = 0; i < actors.length; i++) {
			supplyShares += lend.position(id, actors[i]).supplyShares;
			borrowShares += lend.position(id, actors[i]).borrowShares;
		}

		assertEq(supplyShares, state.totalSupplyShares);
		assertEq(borrowShares, state.totalBorrowShares);
	}
}
