# Permissionless Multi-Relayer Fee Redirection in pallet-ismp-relayer::accumulate_fees

### Protocol: Hyperbridge (pallet-ismp-relayer)
### Severity: High
### Status: Duplicate (Valid)
### Contest Type: Bug Bounty

## Summary
When multiple relayers each deliver messages and earn fees, `accumulate_fees` is supposed to credit each relayer their own earnings. Instead, the aggregation loop accumulates everyone's fees into a single running total, then pays that entire total to whichever relayer's address sorts last alphabetically. The relayers who actually earned the fees receive nothing, and their fee claims are permanently marked as processed - blocking any re-submission. An attacker who controls an address that sorts last can drain every other relayer's unclaimed fees in a single unsigned, permissionless call.

---

## Root Cause

Think of the loop as a cashier handing out pay envelopes. The correct behaviour is: pick up envelope A, hand it to relayer A; pick up envelope B, hand it to relayer B. What the loop actually does is: pick up envelope A, set it aside and forget it; pick up envelope B, set it aside and forget it — then at the end, hand all the cash from all envelopes to whoever was holding the last envelope.

In code, at lines 716–723:

```
let mut total_fee = U256::zero();
let mut delivery_address = Default::default();
for (address, fee) in result.clone().into_iter() {
    delivery_address = address;  // overwrites on every iteration — last write wins
    total_fee += fee;            // but every fee is added to the running total
}
```

`delivery_address` is overwritten on every loop iteration. When the loop finishes, it holds the address of whichever relayer came last in iteration order. `total_fee` holds the sum of every relayer's earnings.

The payout at line 753 then credits that single address with the entire pool:
```
Fees::<T>::try_mutate(state_machine, delivery_address.clone(), |inner| {
    *inner += total_fee;
    ...
});
```

After payout, every commitment in the batch is marked `claimed = true`. The dedup filter at the top of `accumulate_fees` rejects any future submission that contains an already-claimed commitment — so the relayers who received nothing cannot re-submit to claim what they earned.

Why the last address is attacker-controlled: the map iterates in lexicographic order of addresses (standard `BTreeMap` behaviour). An attacker who wants their address to sort last just needs one whose bytes are numerically larger than any victim they are targeting — roughly 256 attempts of vanity generation to guarantee a specific leading byte.

How this was introduced: the code before PR #406 (commit `922aafb`, reviewed by the June 2024 SRLabs audit) credited each relayer individually inside the loop:
```
for (address, fee) in result.clone().into_iter() {
    Fees::<T>::try_mutate(state_machine, address.clone(), |inner| {
        *inner += fee;  // each relayer gets their own fee
        ...
    });
}
```

PR #406 refactored this into a single-recipient aggregation to support a new beneficiary-address feature, and introduced the attribution collapse in doing so. The audit reviewed working code — the defect did not exist at audit time.

---

## Attack Path

1. Attacker generates an address that sorts lexicographically after any target victim's address (~256 vanity attempts for a specific leading byte).

2. Attacker delivers one cheap message on any supported destination chain (BSC, Polygon, Arbitrum) to get their address into the destination's receipt trie. Cost:single-digit USD on a low-gas L2.

3. Attacker watches public chain events for other relayers' unclaimed fee commitments.

4. Attacker builds a `withdrawalProof` that bundles their own commitment together with the victims' unclaimed commitments.

5. Attaacker submits `accumulate_fees` - unsigned, no signature required, no origin check.

6. Loops runs. Attacker's address comes last. Entire fee pool is credited to attacker. All commitments marked `claimed`.

7. Attacker calls `withdraw_fee` and receives the full payout. `EvmHost.sol` transfers unconditionally to the attacker's address.

8. Victims attempt to re-submit their commitments. Dedup filter rejects them - commitments are already claimed. No recovery path exists.
---

## Impact

Any relayer who has earned unclaimed fees can have those fees stolen by an attacker who submits a crafted batch before them. The victims also permanently lose the ability to claim what they earned — the claimed = true flag cannot be reversed and there is no cancel or refund function.

The attack requires no privileged access, no existing relationship with the protocol, and costs effectively nothing to execute. It is repeatable indefinitely as new fees accumulate across new deliveries.

---


## Proof of Concept

Full test: `/accumulate_fees_redirection_poc.rs` — added to the existing relayer pallet test suite at `modules/pallets/testsuite/src/tests/pallet_ismp_relayer.rs`.

The test creates two relayers where `victim address < attacker` address lexicographically, has victim deliver two messages and attacker deliver two messages, then submits a single `accumulate_fees` call bundling all four commitments.

Core assertions:

```
// attacker receives the entire pool despite only earning half
assert_eq!(attacker_credit, total_fee);

// victim earned fees but received nothing
assert_eq!(victim_credit, U256::zero());

// all four commitments permanently marked claimed
for request in &requests {
    let meta = RequestCommitments::<Test>::get(*request).unwrap();
    assert!(meta.claimed);
}

// victim retry is permanently blocked
assert!(retry_result.is_err());
```

**Test output**:

```
$ cargo test -p pallet-ismp-testsuite --lib test_accumulate_fees_multi_relayer_redirection -- --nocapture

    Finished `test` profile [unoptimized + debuginfo] target(s) in 17.55s

running 1 test
test tests::pallet_ismp_relayer::test_accumulate_fees_multi_relayer_redirection_to_lex_last_address ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 117 filtered out; finished in 0.01s
```
---

## Mitigation

**Primary fix** — restore the per-address credit pattern from before PR #406:

```
rustfor (address, fee) in result.iter() {
    Fees::<T>::mutate(state_machine, address.clone(), |inner| *inner += *fee);
}
```

Each relayer gets credited their own fee inside the loop. No single-recipient aggregation, no last-write-wins.

If the beneficiary-address feature is preserved — the beneficiary signature must bind specific commitments attributed to that signer, not just the payout address. Signing only over `keccak256(beneficiary_address)` authenticates where money goes but not who earned it.

Defense in depth — add `ensure!(result.len() == 1, ...)` before the credit operation. This converts any multi-relayer batch into an immediate revert rather than silent theft, until the per-address credit loop is restored.

---

## Tools Used

Manual review, Rust (Substrate test suite)