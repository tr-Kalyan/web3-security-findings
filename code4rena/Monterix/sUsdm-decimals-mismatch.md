# sUSDM decimals() override breaks ERC-20 normalization assumption

## Description

`sUSDM` inherits OpenZeppelin's `ERC4626Upgradeable` and sets `_decimalsOffset() = 6` as inflation defense. With this offset and USDM's 6-decimal precision, sUSDM shares operate internally at 12-decimal precision (each USDM unit corresponds to 10^6 sUSDM share-wei).

However, `sUSDM.decimals()` is overridden to return 6, mirroring the underlying asset
(sUSDM.sol#L106-L112):
```
function _decimalsOffset() internal pure override returns (uint8) {
    return 6;
}

function decimals() public pure override returns (uint8) {
    return 6;
}
```
This creates a 10^6 magnitude mis-scaling between the value reported via `decimals()` and the share precision actually used by the contract.

The team's own test file `sUSDMExchangeRateStrict.t.sol` documents this inconsistency. The `ONE_SUSDM` constant is defined as `1e12` and tests assert that 1e12 share-wei semantically represents "1 sUSDM" (e.g., `assertEq(_rate(), 1e6, "1 sUSDM should start at 1 USDM")` — only valid under 12-decimal interpretation). This contradicts what `decimals() = 6` produces for any external consumer.

## Impact
Any standard ERC-20 consumer relying on `decimals()` for normalization will mis-scale sUSDM balances by a factor of 10^6:

- **Block explorers** (Etherscan, Hyperscan, etc.): display 1,000,000,000 sUSDM for users holding the equivalent of 1,000 USDM
- **Wallets** (MetaMask, Rainbow, Phantom, Trust): show balance values 10^6 times larger than the underlying USDM equivalent, causing user confusion about actual holdings
- **DEX integrations**: A liquidity provider initializing a pool using normalized ERC-20 units (amount × 10^decimals) will misprice the pool by 1e6, enabling immediate extraction via arbitrage.
- **Pricing aggregators and dashboards** (Dune, DeFi Llama, Zapper): TVL and price normalization errors of 10^6 magnitude
- **Naïve UIs** that convert user input via `amount × 10^decimals` would compute share amounts 10^6 times smaller than the user's intended USDM-equivalent value

This is not a cosmetic UI concern. The ERC-20 standard's `decimals()` field exists specifically so that `balance × 10^-decimals` yields the user-facing token amount. Reporting `6` while operating at 12-decimal share precision violates this invariant for any ERC-20 consumer that does not have ERC-4626 awareness — which is the vast majority of standard tooling.

## Proof of Concept

The following test demonstrates the inconsistency. Place in `test/c4/C4Submission.t.sol` and run with `forge test --match-test test_sUSDM_DecimalsDisplayInconsistency -vvv`:

```
function test_sUSDM_DecimalsDisplayInconsistency() public {
    address alice = user1;

    // 1. Verify reported decimals
    uint8 reportedDecimals = susdm.decimals();
    assertEq(reportedDecimals, 6, "sUSDM reports 6 decimals");

    // 2. Alice deposits 1000 USDM (1000e6 raw)
    _deposit(alice, 1000e6);

    vm.startPrank(alice);
    usdm.approve(address(susdm), 1000e6);
    uint256 sharesReceived = susdm.deposit(1000e6, alice);
    vm.stopPrank();

    // 3. Standard ERC-20 UI normalization: balance / 10^decimals
    uint256 uiDisplayedBalance = sharesReceived / (10 ** reportedDecimals);

    // 4. Result: deposit of 1000 USDM displays as 1,000,000,000 sUSDM
    assertEq(sharesReceived, 1_000_000_000_000_000); // 1e15 share-wei
    assertEq(uiDisplayedBalance, 1_000_000_000);     // 1 billion displayed

    // 5. With correct decimals (12), display would be ~1000 sUSDM as expected
    uint256 correctUiDisplay = sharesReceived / (10 ** 12);
    assertEq(correctUiDisplay, 1000);
}
```
Output:
```
Shares received (raw): 1000000000000000
UI displays (shares / 1e6): 1000000000
CORRECT UI display (shares / 1e12): 1000
A 1000 USDM deposit displays as 1,000,000,000 sUSDM in any standard ERC-20 consumer. The team's own tests (sUSDMExchangeRateStrict.t.sol) treat ~1e12 share-wei as "1 sUSDM," consistent only with decimals() = 12.
```

## Recommended Mitigation
Adopt one of two consistent approaches:

**Option A (preferred)**: Remove the `decimals()` override.
```
// Delete:
function decimals() public pure override returns (uint8) {
    return 6;
}
```
OpenZeppelin's default ERC-4626 implementation returns `assetDecimals + _decimalsOffset() = 6 + 6 = 12`, matching the natural share precision and yielding 1:1 unit-level display between USDM and sUSDM.

**Option B**: Set `_decimalsOffset()` to 0.
```
function _decimalsOffset() internal pure override returns (uint8) {
    return 0;
}
```
This keeps `decimals() = 6` consistent but removes the inflation defense provided by the offset. If chosen, the team should adopt an alternative inflation defense such as a minimum-stake-on-init pattern or a small initial dead-shares mint.

Either option restores consistency between `decimals()` and the share precision used internally.