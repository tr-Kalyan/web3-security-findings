# Code4rena — Ekubo Contest

**Status**: Submitted 1 High-severity issue  
**Contest**: Ekubo protocol (2025)  
**Judging**: In progress (as of December 2025)

### Submission Summary
Submitted a High-severity finding focused on unclean assembly inputs in `Core.swap_6269342730`.

**Key Issue**:  
Inline assembly loads `token0` and `token1` directly from calldata without masking upper 96 bits. This allows "dirty" addresses to create ghost debt in shifted storage slots. Repayment logic (in FlashAccountant) cleans inputs, causing slot mismatch → `DebtsNotZeroed` revert and effective fund lock.

**Impact**:  
- Invariant violation (negative pool balances possible via revert)
- Targeted griefing/DoS on critical pools
- Fund lock in bundled transactions (e.g., flash loans)

Full details, root cause, PoC, and recommended mitigation remain private until judging is complete to respect contest rules.

→ Once results are public, the official severity, judge feedback, and full report (including PoC) will be published here.

Happy to discuss my analysis and approach in detail during an interview.