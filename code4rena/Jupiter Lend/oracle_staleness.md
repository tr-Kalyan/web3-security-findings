# Pool-Based Oracle Sources Lack Staleness Validation Enforced on External Feed Sources

### Protocol: Jupiter Lend
### Severity: Low
### Status: Valid
### Contest Type: Audit

---

## Summary

The Oracle program enforces staleness validation on all external price feed sources (Pyth, Chainlink, Redstone) but applies no equivalent check on pool-based sources (mSOL Pool, Single Pool, JupLend). The staleness helper functions exist in `helper.rs` and are called correctly by the external feed modules — they are simply never imported or called from any pool source module.

---

## Root Cause

The asymmetry is direct and grep-verifiable:

**Sources with staleness checks:**

| Module | Mechanism |
|---|---|
| `pyth.rs:31–38` | `get_price_no_older_than()` + `Clock::get()` + `MAX_AGE_OPERATE=600s` / `MAX_AGE_LIQUIDATE=7200s` |
| `chainlink.rs:6,24` | Imports and calls `verify_publish_time_with_slot(data.slot, is_liquidate)` |
| `redstone.rs:7,33–43` | Imports and calls `verify_publish_time(publish_time / MILLISECONDS_PER_SECOND, is_liquidate)` |

**Sources without staleness checks:**

| Module | Observation |
|---|---|
| `msol_pool.rs:12` | Zero clock, timestamp, slot, age, or freshness references in the entire file |
| `single_pool.rs:122` | Zero freshness references in the entire file |
| `jup_lend.rs:38` | The word `fresh` on line 37 is a code comment only, not a check |

The helper functions that would perform the validation already exist at `helper.rs:164` (`verify_publish_time`) and `helper.rs:181` (`verify_publish_time_with_slot`) — they are just never called from pool source modules.

## Pool sources — zero staleness references

```

$ grep -c "verify_publish_time\|MAX_AGE\|Clock::get\|clock\|timestamp\|slot" \
    programs/oracle/src/modules/msol_pool.rs
0
$ grep -c "verify_publish_time\|MAX_AGE\|Clock::get\|clock\|timestamp\|slot" \
    programs/oracle/src/modules/single_pool.rs
0
$ grep -c "verify_publish_time\|MAX_AGE\|Clock::get\|clock\|timestamp\|slot" \
    programs/oracle/src/modules/jup_lend.rs
0

# Helper functions exist but are never imported by pool modules
$ grep -n "pub fn verify" programs/oracle/src/helper.rs
164:pub fn verify_publish_time<'info>(publish_time: u64, is_liquidate: Option<bool>) -> Result<()>
181:pub fn verify_publish_time_with_slot<'info>(
```

---

## Impact

Pool-based sources read live on-chain state rather than off-chain publisher feeds, which weakens the staleness concern relative to Pyth or Chainlink — when the mSOL pool reports an exchange rate, that is the current redeemable rate on-chain at that slot. However, pool state freshness is not fully self-updating:

- The mSOL pool depends on Marinade's crank to reflect accrued staking rewards. If the crank stops, the on-chain exchange rate freezes below actual value.
- Single Pool sources depend on their respective manager cranks.
- The JupLend source reads exchange prices that depend on `rebalance()` being called.

In all three cases, a stale pool state results in an understated price — collateral appears worth less than its actual value. This means a borrower's position can appear undercollateralised at the stale rate when it is actually healthy at the true rate, exposing them to wrongful liquidation. The protocol does not accrue bad debt from this — the harm falls entirely on the borrower who loses collateral to a liquidation that should not have triggered. The risk requires an external failure (crank stops) as a prerequisite rather than an active attacker.

---

## Mitigation

Add a `last_updated_slot` or `last_updated_timestamp` check in each pool source module, consistent with the existing `MAX_AGE` pattern in `pyth.rs`. The validation helpers are already written — the fix is importing and calling them from `msol_pool.rs`, `single_pool.rs`, and `jup_lend.rs` in the same pattern used by the external feed modules.

---

## Tools Used

Manual review