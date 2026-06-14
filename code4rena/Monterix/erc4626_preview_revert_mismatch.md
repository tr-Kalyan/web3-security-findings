# EIP-4626 `max*` and `preview*` Functions Return Values Inconsistent with Always-Revert Behavior

### Protocol: Monetrix
### Severity: Low
### Status: Valid
### Contest Type: Audit

---

## Description

sUSDM overrides `withdraw()` and `redeem()` to revert unconditionally — forcing users through the cooldown flow ([sUSDM.sol#L114-L120](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L114-L120)):

```solidity
function withdraw(uint256, address, address) public pure override returns (uint256) {
    revert UseCooldownFunctions();
}

function redeem(uint256, address, address) public pure override returns (uint256) {
    revert UseCooldownFunctions();
}
```

The team correctly overrode `maxWithdraw()` and `maxRedeem()` to return 0 ([sUSDM.sol#L149-L156](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L149-L156)):

```
function maxWithdraw(address) public pure override returns (uint256) { return 0; }

function maxRedeem(address) public pure override returns (uint256) { return 0; }
```

However, `previewWithdraw()` and `previewRedeem()` are NOT overridden — they retain OpenZeppelin's default implementations that return non-zero values for non-zero inputs.

Additionally, while `maxWithdraw`/`maxRedeem` return 0, the corresponding `withdraw(0, ...)` and `redeem(0, ...)` calls still revert via the unconditional `UseCooldownFunctions` revert. Per EIP-4626:

> "max MUST return ... [a value that] not cause a revert ... in the same transaction."
> "preview MUST return as close to and no more than the exact amount of [shares/assets] that would be returned in a [withdraw/redeem] call in the same transaction."

Both clauses are violated.

---

## Impact

Integrators relying on standard EIP-4626 semantics will hit unexpected reverts in patterns that the spec guarantees are safe:

- A composable contract calling `previewRedeem(N)` to estimate output, then `redeem(N, ...)` to execute, will receive a non-zero estimate followed by an unconditional revert.
- A safety-check pattern using `maxRedeem(user)` to determine "redeem-up-to-max" will receive `0` and attempt `redeem(0, ...)`, which still reverts.
- ERC-4626 SDKs (like Yearn's `yvBaseStrategy`, Sommelier router, etc.) assume preview-then-execute is safe.

This is an integrator safety invariant violation, not just a spec annotation. The standard exists precisely so integrators can rely on these guarantees without contract-specific awareness.

---

## Mitigation

Override `previewWithdraw` and `previewRedeem` to match the always-revert semantics:

```
function previewWithdraw(uint256) public pure override returns (uint256) {
    revert UseCooldownFunctions();
}

function previewRedeem(uint256) public pure override returns (uint256) {
    revert UseCooldownFunctions();
}
```

Additionally, modify `withdraw` and `redeem` to allow the zero-input case to succeed as a no-op (returning 0), so that `max*` returning 0 is honest:

```
function withdraw(uint256 assets, address, address) public pure override returns (uint256) {
    if (assets == 0) return 0;
    revert UseCooldownFunctions();
}

function redeem(uint256 shares, address, address) public pure override returns (uint256) {
    if (shares == 0) return 0;
    revert UseCooldownFunctions();
}
```

This restores spec compliance: `max*` returns a value (0) for which the corresponding call does not revert, and `preview*` revert behavior matches the action behavior.

---

## Tools Used

Manual review