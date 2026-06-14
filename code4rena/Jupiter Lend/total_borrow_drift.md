# Liquidation Subtracts RAW Debt from NET-Debt-Only total_borrow, Causing Permanent Cumulative Accounting Drift

### Protocol: Jupiter Lend
### Severity: Low
### Status: Valid
### Contest Type: Audit


## Summary

The vault's `total_borrow` tracker uses two incompatible debt definitions across its write and read paths. Position creation adds NET debt (excluding dust) to `total_borrows`, but liquidation subtracts RAW debt (including dust) from the same tracker. Every liquidation permanently over-subtracts from `total_borrow` by approximately 0.106% of the liquidated debt. The `absorbed_dust_debt` field that was intended to compensate for this gap is a dead variable written but never read anywhere in the codebase.

---
## Root Cause

**Write path (position creation)** - `total_borrow` tracks NET debt:

```
vault_state.update_total_borrow(memory_vars.get_net_debt_raw()?, old_state.old_net_debt_raw)?;
```

`get_net_debt_raw()` at `structs.rs:174-176` returns `debt-Raw - dust_debt_raw`, explicitly excluding dust.

Tick storage - stores RAW debt including dust:

```
// operate.rs:213-215
let user_raw_debt: u128 = ratio_new.safe_mul(total_col_raw)?.safe_shr(TickMath::SHIFT)?;
```

The tick ratio rounds the position up to the next tick boundary. The difference between this RAW value and the NET value is the dust component.

**Read path (liquidation)** — subtracts RAW debt from the NET-only tracker:
```

// structs.rs:416-418 — accumulates RAW debt from tick processing
pub fn increase_total_debt_liq(&mut self, debt_liquidated: u128) -> Result<()> {
    self.total_debt_liq = self.total_debt_liq.safe_add(debt_liquidated)?;

// user.rs:881 — subtracts that RAW value from the NET-only tracker
vault_state.reduce_total_borrow(current_data.total_debt_liq)?;
```

Since `total_debt_liq` (RAW, includes dust) is always larger than the NET debt that was originally added to `total_borrow`, every liquidation over-subtracts.

**Dead compensation variable**:
`abosrbed_dust_debt` at `vault_state.rs:27` was designed to track this gap. It is written at `user.rs:172` via `update_absorbed_dust_debt_amount()` but is never read by any computation in the codebase - not in the rebalance, not in view functions, not in tests. A full repository grep confirms zero read sites.

---
## Impact

`total_borrow` permanently drifts below the true sum of all positions' net debt. The drift is:


- **One-directional** — dust is always positive (tick ratio always rounds up), so `total_borrow` can only under-count, never over-count.
- **Permanent** — no code path corrects the accumulated deficit. `absorbed_dust_debt` was written to track it but is never consumed.
- **Cumulative** — every liquidation event adds to the deficit independently of prior events.


`total_borrow` is read at `user.rs:1160–1170` during `rebalance()`, where the vault computes a delta against the liquidity layer. An understated `total_borrow` causes the rebalancer to compute an incorrect delta, overpaying the liquidity layer by the accumulated deficit on every rebalance call.

Magnitude: Each liquidation over-subtracts by approximately 0.106% of the liquidated RAW debt (measured at `TICK_SPACING = 10015`). A single liquidation of 3,000 USDT produces an over-subtraction of approximately 374,656 raw units (~0.000374 USDT). For a vault processing 500M USDC in cumulative liquidation volume over its lifetime, the cumulative `total_borrow` understatement reaches approximately 530K USDC.

---
## Mitigation

**Option A (minimal)**: Wire absorbed_dust_debt into reduce_total_borrow so it compensates for the dust component at liquidation time — the tracking was built, it just needs to be consumed.

**Option B**: Track total_borrow in RAW debt throughout, making update_total_borrow use debt_raw instead of get_net_debt_raw(). Eliminates the write/read mismatch entirely.

**Option C**: During liquidation, subtract only the NET portion of the liquidated tick debt from total_borrow rather than the full RAW value.

---
## Tools Used

Manual review, Rust (Anchor test suite)