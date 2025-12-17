// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockGame {
    address public currentKing; // Starts as address(0)
    uint256 public claimFee = 0.01 ether; // Minimal for demo
    uint256 public pot;
    uint256 public totalClaims;

    function claimThrone() external payable {
        require(msg.value >= claimFee, "Insufficient ETH");

        // VULNERABLE: Inverted logic — blocks ALL claims
        require(msg.sender == currentKing, "Game: You are already the king. No need to re-claim.");

        // ... rest skipped — never reached ...

        currentKing = msg.sender;
        pot += msg.value;
        totalClaims++;
    }
}