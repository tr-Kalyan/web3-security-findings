# CodeHawks First Flight #1 — Validated Finding

**Severity**: Medium (validated by judges)  
**Submitted as**: High (appealed for severity upgrade)  
**Issue**: Inverted require logic in `claimThrone()` prevents all claims → permanent DoS

### Description
The check `require(msg.sender == currentKing)` should be `!=`.  
This blocks **every valid claim**, including the very first one needed to bootstrap the game (when `currentKing == address(0)`).

### Impact
- Game never starts from deployment
- Pot remains 0 forever
- No winner can ever be declared
- Users waste gas on reverts

**Appeal Reasoning (for High)**:  
This is a total, irreversible denial of the protocol's core functionality from day 1 — effectively bricking the contract on deployment. While fixable via redeployment, the impact on trust and usability is critical.

### Proof of Concept
See [PoC test](./PoC/InvertedLogicDoSTest.t.sol) and [mock](./PoC/MockGame.sol)

### Recommended Mitigation
Change to `require(msg.sender != currentKing, "Already the king");`

**Tools Used**: Foundry, manual review