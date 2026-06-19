// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract RewardVault {
    mapping(address => uint256) public deposits;

    uint256 public totalDeposits;
    uint256 public rewardPool;

    function deposit() external payable {
        deposits[msg.sender] += msg.value;
        totalDeposits += msg.value;
    }

    function addRewards() external payable {
        rewardPool += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "not enough");

        deposits[msg.sender] -= amount;
        totalDeposits -= amount;

        payable(msg.sender).transfer(amount);
    }

    function claimReward() external {
        require(totalDeposits > 0, "no deposits");
        require(deposits[msg.sender] > 0, "no user deposit");

        uint256 reward = (rewardPool * deposits[msg.sender]) / totalDeposits;

        payable(msg.sender).transfer(reward);
    }
}
