# Shares Burned at Request Time with No Cancel Path Creates Permanent Stuck State When NAV Does Not Recover

### Protocol: Solv BTC+ (Solana)
### Severity: Critical
### Status: Duplicate (Valid)
### Contest Type: Bug Bounty

## Summary

The two-phase withdrawal burns shares irreversibly in Phase 1 and validates NAV tolerance in Phase 2. The backend processes withdrawals within a stated SLA (7 or 14 days depending on amount), and will wait for NAV to recover into tolerance before executing. However, if the NAV at execution time never recovers to within 1% of the NAV recorded at request time, the backend cannot process the withdrawal even if it wants to — the on-chain check will revert. The shares burned in Phase 1 are already gone, there is no cancel function, and there is no refund path. The user is permanently stuck with zero shares and zero tokens.

---

## Root Cause

Withdrawal is split across two separate transactions:

**Phase 1** — `vault_request_withdraw.rs`

```
pub fn vault_withdraw_request(...) {
    ctx.accounts.burn_tokens(amount)?;      // shares destroyed immediately
    ctx.accounts.open_request_account(...) // stores request.nav = current NAV
}
```

Shares are burned via burn_checked CPI at lines 57–72. The request account records request.nav at that moment. No cancellation mechanism exists anywhere in the codebase:

```
bash$ grep -rn "cancel\|refund" programs/solvbtc/src/
# No results
```
**Phase 2** — `vault_withdraw.rs`

```
let max_nav = vault.nav + (vault.nav * 0.01);
require_gte!(max_nav, request.nav, NAVExceeded);
```

The backend must supply an off-chain signature to execute this instruction. The NAV check requires current_nav × 1.01 >= request.nav. If this condition is not met, the instruction reverts. The backend will wait for NAV to recover into tolerance — but if NAV never recovers, the instruction can never succeed. The burn from Phase 1 is not rolled back. The two phases are separate transactions; the burn is final the moment Phase 1 completes.

---
## Attack Path

No attacker required. A sustained NAV depression below the request price is sufficient.

1. Alice calls `vault_withdraw_request` with 1B shares. `burn_checked` executes immediately. `request.nav` is set to 100,000,000. Alice now holds 0 shares.

2. Bitcoin enters a sustained drawdown. NAV drops to 95,000,000 and remains there.

3. Backend attempts to process Alice's withdrawal. The check runs: 95,000,000 × 1.01 = 95,950,000 < 100,000,000. require_gte! fires SolvError::NAVExceeded. Transaction reverts.

4. Backend waits for NAV recovery per SLA. NAV does not recover within 7 or 14 days.

5. SLA expires. Alice holds 0 shares and 0 tokens. There is no cancel path, no re-mint path, and no function the backend can call to refund the burned shares. The request is permanently stuck.

---
## Impact

Any user who requests a withdrawal during a period where NAV subsequently enters a prolonged depression below the request price is permanently stuck. The stuck state has no exit:


- The backend cannot process it — the on-chain NAV check reverts.
- The user cannot cancel it — no cancel function exists.
- The protocol cannot refund it — no re-mint path exists.


The loss compounds over time because shares are burned at request time, not execution time. The user stops accruing yield from the moment of the Phase 1 call. Every day the request sits stuck is a day of yield permanently transferred to remaining shareholders on shares the user no longer owns.

Mainnet evidence at time of submission: 31 active WithdrawRequest accounts held approximately 25.6 BTC+ in burned shares with zero tokens received. Request FAkZhjgSkuN4XUKfQerArrH57ykFbTpqPjHNNo8KknAR (0.001 BTC+) remained stuck for 58 days past its SLA expiry. Five requests had NAV conditions that passed but remained unprocessed, confirming that even when the on-chain condition is satisfiable, backend signing discretion introduces an additional layer of user dependency with no on-chain recourse.

---
## Proof of Concept

Full test suite: `/solvsc189_poc.ts` — 43/43 tests passing against Solv's own repository.

What the PoC demonstrates:


- `vault_withdraw_request` burns shares immediately via `burn_checked` (Step 2)
- A NAV drop of 1.24% blocks `vault_withdraw` with `NAVExceeded` (Step 4)
- User ends with burned shares, zero tokens, and no cancel function available (Step 5)


The failure condition:
```
Stuck when: current_nav < request_nav / 1.01

Example:
  request.nav  = 100,000,000
  current_nav  =  95,000,000   (sustained drawdown)
  max_nav      =  95,000,000 × 1.01 = 95,950,000
  Check:         95,950,000 >= 100,000,000  → FALSE → revert → permanent stuck
```

---
## Mitigation

Implement a cancel function that re-mints the burned shares to the original owner if the withdrawal request has not been executed within the SLA window, or if the NAV condition has not been satisfiable for a defined grace period. This gives the backend an on-chain exit path when NAV recovery is not forthcoming, and gives users recourse independent of backend discretion.

Alternatively, do not burn shares in Phase 1. Hold them in escrow and burn only at the moment of successful execution in Phase 2. This eliminates the irrecoverable stuck state entirely — a failed or expired request simply releases the escrowed shares back to the user.

---
## Tools Used

Manual review, TypeScript (Anchor test suite)