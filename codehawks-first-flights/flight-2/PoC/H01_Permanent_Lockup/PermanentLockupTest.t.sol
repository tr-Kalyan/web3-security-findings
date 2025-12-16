// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "./MockFaucet.sol";

contract PermanentLockupTest is Test {
    MockFaucet faucet;
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        faucet = new MockFaucet();
        faucet.setDailyClaimLimit(1); // 1 claim per day for clear demo
    }

    function test_permanentFaucetLockup() public {
        // Day 1: user1 claims → reaches limit
        vm.prank(user1);
        faucet.claimFaucetTokens();
        assertEq(faucet.dailyClaimCount(), 1);

        // Same day: user2 should fail (expected)
        vm.prank(user2);
        vm.expectRevert(MockFaucet.RaiseBoxFaucet_DailyClaimLimitReached.selector);
        faucet.claimFaucetTokens();

        // Fast-forward 2 full days → no successful claim on day 2
        vm.warp(block.timestamp + 2 days);

        // Day 3: Should reset, but doesn't → still reverts
        vm.prank(user2);
        vm.expectRevert(MockFaucet.RaiseBoxFaucet_DailyClaimLimitReached.selector);
        faucet.claimFaucetTokens();

        // Permanent lockup proven
        assertEq(faucet.dailyClaimCount(), 1); // Never reset
    }
}