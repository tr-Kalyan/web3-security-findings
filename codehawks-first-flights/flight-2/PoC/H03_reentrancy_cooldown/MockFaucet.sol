// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockFaucet {
    mapping(address => uint256) public lastClaimTime;
    uint256 public constant CLAIM_COOLDOWN = 3 days;

    uint256 public dailyClaimCount;
    uint256 public dailyClaimLimit = 100;

    mapping(address => bool) public hasClaimedEth;
    uint256 public sepEthAmountToDrip = 0.01 ether;
    bool public sepEthDripsPaused = false;

    // Simulate token drip (we don't need full ERC20)
    uint256 public faucetDrip = 1000 * 10**18;

    receive() external payable {}

    function claimFaucetTokens() external {
        address claimant = msg.sender;

        // Checks (cooldown and daily limit)
        if (block.timestamp < lastClaimTime[claimant] + CLAIM_COOLDOWN) {
            revert("Cooldown active");
        }
        if (dailyClaimCount >= dailyClaimLimit) {
            revert("Daily limit reached");
        }

        // ETH drip for first-time claimers — VULNERABLE INTERACTION BEFORE EFFECTS
        if (!hasClaimedEth[claimant] && !sepEthDripsPaused) {
            hasClaimedEth[claimant] = true;

            (bool success,) = claimant.call{value: sepEthAmountToDrip}("");
            require(success, "ETH transfer failed");
        }

        // VULNERABLE: Effects AFTER external call
        lastClaimTime[claimant] = block.timestamp;
        dailyClaimCount++;

        // Simulate token transfer (no actual ERC20 needed for PoC)
        // In real exploit, this would transfer tokens multiple times
    }
}