// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "./MockFaucet.sol";
import "./ReentrancyAttacker.sol";

contract ReentrancyTest is Test {
    MockFaucet faucet;
    ReentrancyAttacker attacker;

    function setUp() public {
        faucet = new MockFaucet();
        vm.deal(address(faucet), 1 ether); // Fund faucet for ETH drips

        attacker = new ReentrancyAttacker(address(faucet));
    }

    // H-03: Reentrancy bypasses cooldown and daily claim count
    function test_reentrancyCooldownBypass() public {
        uint initialDailyCount = faucet.dailyClaimCount();

        // Attacker triggers the first call
        vm.prank(address(attacker));
        attacker.attack();

        // Reentrancy succeeded — multiple state updates in one tx
        assertGt(faucet.dailyClaimCount(), initialDailyCount + 1);
        assertEq(attacker.callsMade(), 5); // Re-entered 5 times
    }
}