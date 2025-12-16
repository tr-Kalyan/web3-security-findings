// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockFaucet {
    uint256 public dailyClaimCount;
    uint256 public dailyClaimLimit = 1; // Low for clear demo
    uint256 public lastFaucetDripDay;

    error RaiseBoxFaucet_DailyClaimLimitReached();

    function claimFaucetTokens() external {
        // Vulnerable check — before reset
        if (dailyClaimCount >= dailyClaimLimit) {
            revert RaiseBoxFaucet_DailyClaimLimitReached();
        }

        // ... skipped logic ...

        // Vulnerable reset — after check
        if (block.timestamp > lastFaucetDripDay + 1 days) {
            lastFaucetDripDay = block.timestamp;
            dailyClaimCount = 0;
        }

        dailyClaimCount++;
    }

    // Helper for test setup
    function setDailyClaimLimit(uint256 _limit) external {
        dailyClaimLimit = _limit;
    }
}