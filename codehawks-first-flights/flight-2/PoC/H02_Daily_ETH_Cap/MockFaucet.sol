// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockFaucet {
    mapping(address => bool) public hasClaimedEth;
    uint256 public dailyDrips;
    uint256 public dailySepEthCap = 0.02 ether; // 2 claims at 0.01 each
    uint256 public sepEthAmountToDrip = 0.01 ether;
    bool public sepEthDripsPaused = false;

    uint256 public lastDripDay;

    // Simulate contract having ETH balance
    receive() external payable {}

    function claimFaucetTokens() external payable {
        address claimant = msg.sender;

        if (!hasClaimedEth[claimant] && !sepEthDripsPaused) {
            uint256 currentDay = block.timestamp / 24 hours;

            if (currentDay > lastDripDay) {
                lastDripDay = currentDay;
                dailyDrips = 0;
            }

            if (dailyDrips + sepEthAmountToDrip <= dailySepEthCap) {
                hasClaimedEth[claimant] = true;
                dailyDrips += sepEthAmountToDrip;

                // Simulate ETH drip (success)
                payable(claimant).transfer(sepEthAmountToDrip);
            }
            // else skip — no drip
        } else {
            // VULNERABLE: Resets daily counter for repeat claimers
            dailyDrips = 0;
        }

        // ... other logic skipped ...
    }
}