# WrappedNative Withdrawal Path in `_distributeOrCollectLiquidityToken` Lacks `_storedTokensOwed` Fallback, Permanently Locking LP Funds for Contract-Based Providers

### Protocol: Limit Break AMM
### Severity: Medium
### Status: Valid
### Contest Type: Audit

## Summary

`_distributeOrCollectLiquidityToken` in `AMMModule.sol handles token distributions to liquidity providers through two branches:
- an ERC20 path that gracefully stores failed transfers as debt via `_storedTokensOwed`
- and a `wrappedNative` path that sends raw ETH with no error handling


When a contract-based LP cannot receive ETH, every call to `removeLiquidity`, `addLiquidity` (fee collection), or `collectFees` reverts entirely - locking both the `wrappedNative` and the paired token permanently with no recovery path.

---
## Root Cause

The bug is in `_distributeOrCollectLiquidityToken` at `AMMModule.sol:1282–1304`. When distributing tokens to a provider (negative `netAmount`), the function takes two branches:

`wrappedNative` branch — no fallback:
```
if (token == address(wrappedNative)) {
    wrappedNative.withdrawToAccount(provider, unsignedAmount);
}
```

ERC20 branch — has fallback:

```
// AMMModule.sol:1298-1301
} else {
    bool isError = SafeERC20.safeTransfer(token, provider, unsignedAmount);
    if (isError) {
        _storeTokensOwed(provider, token, unsignedAmount);
    }
}
```

`withdrawToAccount` calls `_withdrawFromAccount` in `WrappedNative.sol:651–668`, which sends raw ETH via assembly and hard-reverts on failure:
```
if or(gt(updatedBalance, balanceVal), iszero(call(gas(), to, amount, 0, 0, 0, 0))) {
    revert(0,0)
}
```

If the ETH transfer to the LP fails, the entire transaction reverts with no data. There is no `try/catch` in the calling code, no error return, and no fallback to `_storeTokensOwed`.

Both token distributions happen sequentially inside `_distributeAndCollectLiquidityTokens (AMMModule.sol:1247–1260)`:

```
bool nativeValueUsed0 = _distributeOrCollectLiquidityToken(provider, token0, netAmount0);
bool nativeValueUsed1 = _distributeOrCollectLiq
```

When the `wrappedNative` distribution reverts, the entire transaction rolls back — including the paired ERC20 token distribution. Both tokens remain locked in the pool.

Developer intent is clear. The NatSpec on `_distributeOrCollectLiquidityToken (AMMModule.sol:1275)` explicitly states:


> "Failed transfers stored as owed amounts"



And `removeLiquidity (ModuleLiquidity.sol:168)` documents:


> "Failed token transfers stored as debt rather than causing reverts"



The team built `_storeTokensOwed`, documented it as a postcondition, and applied it to the ERC20 branch. The `wrappedNative` branch is missing the same protection.

---

## Attack Path

1. A contract-based LP — Gnosis Safe with a transaction guard, account abstraction wallet, DAO vault, or any contract with no `receive()` function — calls `addLiquidity()` on a pool where one token is `wrappedNative`. The deposit succeeds because the deposit path uses `_depositWrappedNativeAndRefundExcess`, which handles wrapped native correctly.
2. Fees accumulate. The LP calls `removeLiquidity()`.
3. Execution reaches `_distributeOrCollectLiquidityToken()` for the `wrappedNative` token with a negative `netAmount`.
4. `wrappedNative.withdrawToAccount(provider, unsignedAmount)` unwraps WETH and sends raw ETH to the LP's contract address.
5. The raw ETH transfer fails — the LP contract rejects ETH.
6. `_withdrawFromAccount` executes `revert(0,0)`. No `try/catch` exists in the calling code. The revert propagates up through the entire call chain.
7. The entire transaction reverts. No state changes persist. No debt is recorded.
8. Every subsequent `removeLiquidity()`, `addLiquidity()`, and `collectFees()` call hits the same revert.
9. The LP's funds — both `wrappedNative` and the paired token — are permanently locked. Since `_storeTokensOwed` was never called, `collectTokensOwed()` has nothing to return.

---
## Impact

Contract-based liquidity providers on any pool containing `wrappedNative` face permanent, irreversible loss of their entire position — both the `wrappedNative` token and the paired token. The funds are locked in the pool reserves with no recovery mechanism.

The LP has no way to avoid this. The deposit path works correctly so the failure only manifests on withdrawal, after funds are already committed. There is no emergency withdrawal function, no admin rescue function, and no workaround — `collectTokensOwed` only works when `_storeTokensOwed` was previously called, which never happens for `wrappedNative` failures.

Affected LP types include Gnosis Safes with transaction guards, ERC-4337 account abstraction wallets, DAO treasury contracts, and protocol vaults — all common patterns in DeFi.

---
## Mitigation

Wrap the `withdrawToAccount` call in a `try/catch` and fall back to `_storeTokensOwed`, matching the ERC20 path's existing behaviour:

```
solidity} else if (netAmount < 0) {
    uint256 unsignedAmount = uint256(-netAmount);
    if (token == address(wrappedNative)) {
        try wrappedNative.withdrawToAccount(provider, unsignedAmount) {
        } catch {
            _storeTokensOwed(provider, token, unsignedAmount);
        }
    } else {
        bool isError = SafeERC20.safeTransfer(token, provider, unsignedAmount);
        if (isError) {
            _storeTokensOwed(provider, token, unsignedAmount);
        }
    }
}
```
When ETH delivery fails, the `wrappedNative` amount is recorded as debt in the `tokensOwed` mapping, recoverable via `collectTokensOwed`. The LP receives WETH as an ERC20 transfer — which their contract can handle — instead of raw ETH.

---
## Tools Used

Manual review