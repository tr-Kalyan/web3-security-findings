// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./MockGame.sol";

contract InvertedLogicDoSTest is Test {
    MockGame game;
    address player1 = address(0x1);
    address player2 = address(0x2);

    function setUp() public {
        game = new MockGame();
    }

    // Validated finding: Inverted require prevents all claims → permanent DoS
    function test_claimThronePermanentlyBlocked() public {
        // Initial state: no king
        assertEq(game.currentKing(), address(0));
        assertEq(game.pot(), 0);
        assertEq(game.totalClaims(), 0);

        // First claim (should bootstrap game) — reverts
        vm.prank(player1);
        vm.expectRevert("Game: You are already the king. No need to re-claim.");
        game.claimThrone{value: 0.01 ether}();

        // State unchanged — game never starts
        assertEq(game.currentKing(), address(0));
        assertEq(game.pot(), 0);
        assertEq(game.totalClaims(), 0);

        // Overpay — still fails
        vm.prank(player1);
        vm.expectRevert("Game: You are already the king. No need to re-claim.");
        game.claimThrone{value: 0.1 ether}();

        // Different player — still fails
        vm.prank(player2);
        vm.expectRevert("Game: You are already the king. No need to re-claim.");
        game.claimThrone{value: 0.01 ether}();

        // Permanent DoS proven
    }
}