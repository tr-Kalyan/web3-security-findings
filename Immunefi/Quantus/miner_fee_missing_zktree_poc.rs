#[test]
fn poc_miner_volume_fee_credit_has_no_zk_leaf() {
    use sp_runtime::traits::ValidateUnsigned;

    new_test_ext().execute_with(|| {
        let proof = deserialize_test_proof();
        let inputs = parse_private_batch_public_inputs(&proof).expect("fixture must parse");

        let block_number = inputs.block_data.block_number as u64;
        let block_hash_bytes: [u8; 32] =
            inputs.block_data.block_hash.as_ref().try_into().expect("32-byte hash");
        frame_system::BlockHash::<Test>::insert(block_number, H256::from(block_hash_bytes));
        System::set_block_number(block_number + 10);

        // This is the same pre-runtime-digest route QPoW uses. The runtime derives
        // the credited AccountId from this preimage, rather than receiving a
        // normal transaction signer.
        let miner_preimage = [7u8; 32];
        set_miner_preimage_digest(miner_preimage);
        let miner = sp_core::crypto::AccountId32::from(
            qp_wormhole::derive_wormhole_address(miner_preimage)
                .expect("test preimage limbs are canonical"),
        );

        let exit_leaf_count = inputs
            .account_data
            .iter()
            .filter(|account| account.summed_output_amount > 0)
            .count() as u64;
        let exit_quanta: u128 = inputs
            .account_data
            .iter()
            .filter(|account| account.summed_output_amount > 0)
            .map(|account| account.summed_output_amount as u128)
            .sum();
        let total_fee = super::ceil_volume_fee(exit_quanta, VolumeFeeRateBps::get() as u128);
        let miner_fee = total_fee - total_fee / 2;
        assert!(miner_fee > 0, "fixture must produce a miner fee");

        let balance_before = Balances::free_balance(miner.clone());
        let leaves_before = ZkTree::leaf_count();
        let transfer_count_before = Wormhole::transfer_count(&miner);
        let proof_bytes = get_test_proof_bytes();
        let call = crate::Call::<Test>::verify_private_batch {
            proof_bytes: proof_bytes.clone(),
        };

        // In a real unsigned extrinsic this runs before dispatch. It performs the
        // full ZK verification; the dispatch body below deliberately performs only
        // cheap parsing before it settles the already-verified bundle.
        assert!(
            <Wormhole as ValidateUnsigned>::pre_dispatch(&call).is_ok(),
            "the real proof fixture must pass full ZK verification before settlement"
        );

        assert_ok!(Wormhole::verify_private_batch(
            RawOrigin::None.into(),
            proof_bytes,
        ));

        // The fee is real: a successful balance credit and its cosmetic event exist.
        assert_eq!(Balances::free_balance(miner.clone()), balance_before + miner_fee);
        System::assert_has_event(
            crate::Event::<Test>::MinerVolumeFeePaid { miner: miner.clone(), amount: miner_fee }
                .into(),
        );

        // Only the users' exit credits produced leaves. The miner credit produced
        // neither the leaf nor the count that a leaf proof requires.
        assert_eq!(ZkTree::leaf_count(), leaves_before + exit_leaf_count);
        assert_eq!(Wormhole::transfer_count(&miner), transfer_count_before);
        assert!(
            (0..ZkTree::leaf_count()).all(|index| {
                let leaf = ZkTree::leaf(index).expect("all indices below leaf_count exist");
                leaf.to != miner
            }),
            "the credited miner must have no ZK-tree leaf"
        );
        println!(
            "PoC reproduced: miner fee = {miner_fee}; miner balance = {}; \
                ZK leaves = {leaves_before} -> {}; miner TransferCount = {transfer_count_before} -> {}",
            Balances::free_balance(miner.clone()),
            ZkTree::leaf_count(),
            Wormhole::transfer_count(&miner),
        );
    });
}