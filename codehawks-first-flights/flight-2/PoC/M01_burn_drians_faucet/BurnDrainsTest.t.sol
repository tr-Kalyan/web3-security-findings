// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "./MockFaucet.sol";

contract BurnDrainsTest is Test {
    MockFaucet faucet;
    address owner = address(0xOWNER);

    function setUp() public {
        vm.startPrank(owner);
        faucet = new MockFaucet();
        vm.stopPrank();
    }

    // M-01: burnFaucetTokens drains entire balance to caller
    function test_burnDrainsAllTokensToOwner() public {
        uint256 initialFaucetBalance = faucet.balanceOf(address(faucet));
        uint256 initialOwnerBalance = faucet.balanceOf(owner);

        uint256 burnAmount = 100 * 10**18; // Owner intends to burn only 100 tokens

        // Owner calls burn function
        vm.prank(owner);
        faucet.burnFaucetTokens(burnAmount);

        uint256 finalFaucetBalance = faucet.balanceOf(address(faucet));
        uint256 finalOwnerBalance = faucet.balanceOf(owner);

        // Faucet should be completely drained
        assertEq(finalFaucetBalance, 0, "Faucet should have 0 tokens left");

        // Owner receives full supply minus only the burned amount
        assertEq(
            finalOwnerBalance,
            initialFaucetBalance - burnAmount,
            "Owner receives almost entire supply"
        );
    }
}