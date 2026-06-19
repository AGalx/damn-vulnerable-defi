// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RewardVault} from "../../src/manual-fuzzing/RewardVault.sol";

contract RewardVaultHandler is Test {
    RewardVault public vault;
    address[] public users;

    uint256 public ghostDeposits;
    uint256 public ghostRewards;
    uint256 public ghostWithdrawals;
    uint256 public ghostClaims;

    constructor(RewardVault _vault) {
        vault = _vault;

        users.push(makeAddr("Alice"));
        users.push(makeAddr("Bob"));
        users.push(makeAddr("Charlie"));
        users.push(makeAddr("Dave"));
    }

    function deposit(uint256 seed, uint256 amount) public {
        address actor = users[seed % users.length];
        amount = bound(amount, 1, 100 ether);

        vm.deal(actor, amount);

        vm.prank(actor);
        vault.deposit{value: amount}();

        ghostDeposits += amount;
    }

    function addRewards(uint256 seed, uint256 amount) public {
        address actor = users[seed % users.length];
        amount = bound(amount, 1, 100 ether);

        vm.deal(actor, amount);

        vm.prank(actor);
        vault.addRewards{value: amount}();

        ghostRewards += amount;
    }

    function withdraw(uint256 seed, uint256 amount) public {
        address actor = users[seed % users.length];
        uint256 balance = vault.deposits(actor);

        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(actor);
        vault.withdraw(amount);

        ghostWithdrawals += amount;
    }

    function claimReward(uint256 seed) public {
        address actor = users[seed % users.length];
        uint256 beforeBalance = address(vault).balance;

        vm.prank(actor);
        vault.claimReward();

        ghostClaims += beforeBalance - address(vault).balance;
    }
}

contract RewardVaultInvariantTest is Test {
    RewardVault public vault;
    RewardVaultHandler public handler;

    function setUp() public {
        vault = new RewardVault();
        handler = new RewardVaultHandler(vault);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.addRewards.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.claimReward.selector;

        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    function invariant_vaultAccounting() public view {
        assertEq(
            address(vault).balance,
            vault.totalDeposits() + vault.rewardPool()
        );
    }

    function invariant_ghostAccounting() public view {
        assertEq(
            address(vault).balance,
            handler.ghostDeposits() +
                handler.ghostRewards() -
                handler.ghostWithdrawals() -
                handler.ghostClaims()
        );
    }

    function invariant_userDepositsSync() public view {
        uint256 sumDeposits;

        for (uint256 i = 0; i < 4; i++) {
            sumDeposits += vault.deposits(handler.users(i));
        }

        assertEq(sumDeposits, vault.totalDeposits());
    }
}
