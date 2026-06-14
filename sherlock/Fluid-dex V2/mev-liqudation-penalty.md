# Pool-price-based D3 liquidation penalty weighting enables MEV-extractable value beyond oracle-assessed risk

### Protocol: Fluid DEX V2
### Severity: Medium
### Status: Valid
### Contest Type: Audit

## Summary

D3 Liquidation reads two different prices in the same transaction. The token composition that feeds into `averageLiquidationPenalty_` is computed at the live DEX pool `sqrtPriceX96`, while the post-liquidation health-factor check is computed at an oracle-derived price. Pool price can be moved intra-transaction by anyone with the capital to swap in the pool, and the oracle cannot. Attacker swaps to skew composition toward the higher-penalty token, inflates the blended penalty, and over-seizes collateral. The HF check at oracle price does not observe the manipulation.

## Root Cause

A D3 position is a two-token concentrated-liquidity range, with each token carrying its own configured liquidation applies a blended penalty weighted by the position's token composition at the time of liquidation, computed in `liquidationModule/main.sol`:

```
averageLiquidatoinPenalty_ = (
    (v1_.token0LiquidationPenalty * supplyValue0_) +
    (v1_.token1LiquidationPenalty * supplyValue1_)
) / supplyValue_;

```

Seized collateral scales with this blended penalty as `withdrawValue = paybackValue * (1000 + averageLiquidityPenalty_) / 1000`.

Token composition is derived from `AT_POOL_PRICE`, the live pool `sqrtPriceX96` read directly from DEX variables:

```solidity
sqrtPriceX96: AT_POOL_PRICE;

(token0SupplyAmount_, token1SupplyAmount_) = getAmountsForLiquidity(sqrtPriceX96, ...);
```

The post-liquidation HF check uses and oracle-derived `sqrtPriceX96` through `_calculateSqrtPriceX96` and `_getHFInfo`, not the pool price. Because penalty weighting and the HF check read from two independent price sources within the same transaction, an attacker can move the weighting price without moving the safety-check price.

## Attack Path

In a normal liquidation the protocol decomposes the borrower's position at pool price and applies the resulting belned penalty. The exploit changes nothing about the borrower, payback, oracle, or liquidation eligibility, only the pool state immediately before `liquidate()`.

Setup: D3 position 50/50 by oracle value, with token0 at 5% liquidation penalty and token1 at 15%.

1. Attacker swaps inside the DEX-V2 pool to push spot price toward token1. Composition at pool price shifts from 50/50 to roughly 10/90.
2. Attacker calls `liquidate()`. Supply amounts re computed at manipulated pool price, giving the protocol a composition of 10% of token0 and 90% of token1. The blended penalty becomes `(5% * 10%) + (15% * 90%) = 14%`, instead of the honest `(5% * 50%) + (15% * 50%) = 10%`.
3. `withdrawValue` is scaled by the inflated 14% penalty rather than the fair 10%, and the liquidator receives additional collateral.
4. Attacker swaps back to unwind the price move. In a sandwich the bulk of the round-trip cost is recovered.
5. The post-liquidation HF checks values the result at oracle price. Oracle did not move, so the check passes.

## Impact

Borrowers lose collateral in excess of the oracle-assessed penalty on every successful liquidation of this type. On a $500K liquidation with the parameters above, attacker extracts approximately $22.5K of additional borrower collateral over a normal liquidation. The attack is repeatable across positions and across liquidations.

The loss is bounded by three protocol-level constraints. The spread between the two token's liquidation penalties is adming-set and capped per toen. The composition shift achievable on the pool is a function of local in-range liquidity versus attacker capital. `hfLimit` caps how much of a position can be liquidated in a single call. These bounds make the loss constrained rather than arbitrary, but the borrower's seizure still depends on a permissionless input the attacker controls within those bounds.

The realizable case is a D3 position large enough relative to local in-range liquidity that a feasible front-run materially shifts composition, combined with a meaningful penalty differential between the two collateral tokens. A stable/volatile pair with the standard 5-10 percentage-point differential between stable and volatile penalties is sufficient. In that case attacker has positive net incentive after swap fees and gas, so the manipulation is a profitable sandwich rther than greifing.

A natural objection is that seizure self-normalizes, because `withdrawValue/supplyValue_` cancels the pool price by using the same spot-derived composition in numerator and denominator. This does not resolve the issue. `averageLiquidationPenalty` enters `withdrawValue` as an additive markup on `paybackValue`, before any normalizing ratio. Once it is inflated, `withdrawValue` is inflated, and no downstream ratio undoes it.

## PoC
The PoC isolates the penalty-scaling path. It re-implements Fluid's protocol math (`rawToNormal`, the supply-value-weighted blended penalty, `scaleWithdraw`) and Uniswap V3's `TickMath`, `FullMath`, and `LiquidityAmounts` inline. Three scenarios run from identical inputs, with only `sqrtPriceX96` varying: fair (pool equals oracle), moderate (pool pushed 70% toward upper tick), and full manipulation (pool at upper tick).

Full test: [`PoC/liquidation_penalty_poc.sol`](./liquidation_penalty_poc.sol)

Position configuration: token0 at 5% penalty with $3000 oracle, token1 at 15% penalty with $1 oracle, tick range 78244–81610 (~$2500–$3500), liquidity 500K, payback $500K.

Output:
```
==== FAIR (pool = oracle) ====
  Penalty (permil)  : ~104     (10.4%)
  Seized ($)        : ~552,000

==== MANIPULATED (pool -> upper tick) ====
  Penalty (permil)  : ~149     (14.9%)
  Seized ($)        : ~574,500

==== MODERATE (70% push) ====
  Penalty (permil)  : (between fair and full)
  Seized ($)        : (between fair and full)

==== VALUE EXTRACTION ====
  Extra full ($)    : ~22,500
  Extra moderate ($): (positive, monotonic in push depth)
```
A second test `test_Penalty_Monotonically_Increases` sweeps the pool price across 20 tick steps. The blended penalty is non-decreasing across the sweep, which confirms the attacker's gain is smooth in manipulation depth rather than a knife-edge artifact.

## Tool used
Manual review, Foundry.

## Mitigation
Weight `averageLiquidationPenalty_` using the same oracle-derived `sqrtPriceX96` that `_getHfInfo` uses for the post-liquidation health-factor check, rather than `AT_POOL_PRICE`. Aligning the penalty-weighting basis with the solvency-check basis removes the intra-transaction divergence the attack depends on. An attacker cannot move the weighting price without also moving the safety-check price, and the oracle is not manipulable within a single transaction.


If pool-price-based composition is needed elsewhere for correctness, constrain the weighting price to the oracle using a TWAP or oracle-clamped fallback, so the weighting cannot be pushed outside the safety check's view.