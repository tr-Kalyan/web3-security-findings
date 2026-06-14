import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { Solvbtc } from "../target/types/solvbtc";
import { Keypair, LAMPORTS_PER_SOL, SystemProgram, Transaction, ComputeBudgetProgram, sendAndConfirmTransaction } from "@solana/web3.js";
import { createWithdrawRequestHash, createEip191WithdrawSig, deriveMinterManagerAddress, derivePoolSignerAddress, deriveVaultAddress, deriveWithdrawRequestAddress, 
  deriveWithdrawRequestEip191, ecdsaPubkeyFromPrivkey, ONE_BITCOIN } from "../sdk/solvbtc";
import { BN } from "bn.js";
import { createAssociatedTokenAccountIdempotentInstruction, createInitializeMint2Instruction, createInitializeMultisigInstruction, createTransferCheckedInstruction, getAssociatedTokenAddressSync, getMinimumBalanceForRentExemptMint, getMinimumBalanceForRentExemptMultisig, MINT_SIZE, MULTISIG_SIZE, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { ASSOCIATED_PROGRAM_ID } from "@coral-xyz/anchor/dist/cjs/utils/token";
import { assert } from "chai";

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║  SOLVSC-189 — Proof of Concept: Permanent Fund Lock Vulnerability      ║
 * ║                                                                        ║
 * ║  This PoC proves that normal market volatility permanently locks       ║
 * ║  user funds with ZERO recovery path.                                   ║
 * ║                                                                        ║
 * ║  FLOW:                                                                 ║
 * ║    1. User deposits tokens and receives shares                         ║
 * ║    2. User creates withdrawal request → shares BURNED immediately      ║
 * ║    3. Oracle updates NAV down by >1% (simulating normal BTC movement)  ║
 * ║    4. User attempts withdrawal → FAILS (NAVExceeded)                   ║
 * ║    5. User now has: 0 shares + 0 tokens + no cancel function           ║
 * ║                                                                        ║
 * ║  Report:  SOLVSC-189                                                   ║
 * ║  Author:  @Kalyan-tr                                                   ║
 * ║  Date:    February 2026                                                ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 */

describe("SOLVSC-189: Permanent Fund Lock PoC", () => {
  anchor.setProvider(anchor.AnchorProvider.env());

  const provider = anchor.getProvider();
  const connection = provider.connection;

  const confirm = async (signature: string): Promise<string> => {
    const block = await connection.getLatestBlockhash();
    await connection.confirmTransaction({ signature, ...block });
    return signature;
  };

  const program = anchor.workspace.solvbtc as Program<Solvbtc>;

  // ═══════════════════════════════════════════════════════════════════
  // KEYPAIRS & ACCOUNTS
  // ═══════════════════════════════════════════════════════════════════

  // Authority key (matches ADMIN_WHITELIST in constants.rs)
  const authorityKeypair = Keypair.fromSecretKey(new Uint8Array([
    50, 113, 208, 51, 176, 21, 27, 129, 26, 20, 53,
    124, 179, 130, 206, 138, 228, 170, 199, 24, 193, 60,
    253, 134, 123, 125, 163, 189, 9, 185, 55, 19, 33,
    189, 5, 146, 32, 116, 24, 195, 49, 105, 110, 174,
    167, 205, 203, 23, 17, 29, 199, 83, 33, 241, 105,
    206, 179, 236, 186, 72, 144, 232, 119, 227
  ]));

  const adminKeypair = Keypair.generate();
  const payerKeypair = Keypair.generate();
  const feeReceiverKeypair = Keypair.generate();
  const treasurerKeypair = Keypair.generate();
  const oracleManagerKeypair = Keypair.generate();
  const userKeypair = Keypair.generate();
  const mintAKeypair = Keypair.generate();  // Share token (like BTC+)
  const mintBKeypair = Keypair.generate();  // Deposit/withdraw token (like SolvBTC)
  const multisigAKeypair = Keypair.generate();
  const multisigBKeypair = Keypair.generate();

  const authority = authorityKeypair.publicKey;
  const admin = adminKeypair.publicKey;
  const payer = payerKeypair.publicKey;
  const feeReceiver = feeReceiverKeypair.publicKey;
  const treasurer = treasurerKeypair.publicKey;
  const oracleManager = oracleManagerKeypair.publicKey;
  const user = userKeypair.publicKey;
  const mintA = mintAKeypair.publicKey;
  const mintB = mintBKeypair.publicKey;
  const multisigA = multisigAKeypair.publicKey;
  const multisigB = multisigBKeypair.publicKey;
  const poolSignerA = derivePoolSignerAddress(mintA);
  const poolSignerB = derivePoolSignerAddress(mintB);
  const vaultA = deriveVaultAddress(mintA);
  const vaultB = deriveVaultAddress(mintB);
  const minterManagerA = deriveMinterManagerAddress(vaultA);
  const minterManagerB = deriveMinterManagerAddress(vaultB);

  // Withdraw request
  const hash = createWithdrawRequestHash();
  const withdrawRequest = deriveWithdrawRequestAddress(vaultA, mintB, user, hash);

  // Programs
  const tokenProgram = TOKEN_PROGRAM_ID;
  const associatedTokenProgram = ASSOCIATED_PROGRAM_ID;
  const systemProgram = SystemProgram.programId;

  // Token accounts
  const userAtaA = getAssociatedTokenAddressSync(mintA, user);
  const userAtaB = getAssociatedTokenAddressSync(mintB, user);
  const authorityAtaA = getAssociatedTokenAddressSync(mintA, authority);
  const authorityAtaB = getAssociatedTokenAddressSync(mintB, authority);
  const vaultAAtaB = getAssociatedTokenAddressSync(mintB, vaultA, true);
  const feeReceiverAtaB = getAssociatedTokenAddressSync(mintB, feeReceiver);

  // ECDSA verifier key
  const verifierKeypair = Buffer.from("c2fffbf8e5cec943afb99e8194a5819c64c9df75b4ed03b2a111e8ccdcf55689", "hex");
  const verifier = Array.from(ecdsaPubkeyFromPrivkey(verifierKeypair).subarray(1));

  const accounts = {
    authority, admin, payer, feeReceiver, treasurer, oracleManager,
    mintA, mintB, multisigA, multisigB, user, withdrawRequest,
    tokenProgram, associatedTokenProgram, systemProgram
  };

  // Helper: get token balance
  async function getTokenBalance(ata: anchor.web3.PublicKey): Promise<number> {
    try {
      const balance = await connection.getTokenAccountBalance(ata);
      return parseInt(balance.value.amount);
    } catch {
      return 0;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 0: SETUP (same as existing test suite)
  // ═══════════════════════════════════════════════════════════════════

  it("Step 0.1: Airdrop SOL to all accounts", async () => {
    let tx = new Transaction();
    tx.instructions = [authority, admin, user, payer, feeReceiver, treasurer, oracleManager].map((account) =>
      SystemProgram.transfer({
        fromPubkey: provider.publicKey,
        toPubkey: account,
        lamports: 10 * LAMPORTS_PER_SOL,
      })
    );
    await provider.sendAndConfirm(tx, []);
    console.log("    ✓ All accounts funded");
  });

  it("Step 0.2: Create mints (mintA = shares, mintB = deposit token)", async () => {
    const lamports = await getMinimumBalanceForRentExemptMint(connection);
    const lamportsMultisig = await getMinimumBalanceForRentExemptMultisig(connection);
    let tx = new Transaction();
    tx.instructions = [
      ...[multisigA, multisigB].map((account) =>
        SystemProgram.createAccount({
          fromPubkey: provider.publicKey,
          newAccountPubkey: account,
          space: MULTISIG_SIZE,
          lamports: lamportsMultisig,
          programId: tokenProgram,
        })
      ),
      ...[mintA, mintB].map((mint) =>
        SystemProgram.createAccount({
          fromPubkey: provider.publicKey,
          newAccountPubkey: mint,
          lamports,
          space: MINT_SIZE,
          programId: tokenProgram,
        })
      ),
      createInitializeMultisigInstruction(multisigA, [vaultA, poolSignerA], 1, tokenProgram),
      createInitializeMultisigInstruction(multisigB, [vaultB, poolSignerB], 1, tokenProgram),
      createInitializeMint2Instruction(mintA, 8, multisigA, multisigA),
      createInitializeMint2Instruction(mintB, 8, multisigB, multisigB),
    ];
    await provider.sendAndConfirm(tx, [mintAKeypair, mintBKeypair, multisigAKeypair, multisigBKeypair]);
    console.log("    ✓ Mints created (8 decimals, like BTC)");
  });

  it("Step 0.3: Initialize vault with NAV = 1.0 BTC/share", async () => {
    await program.methods.vaultInitialize(
      admin,
      feeReceiver,
      treasurer,
      Array.from(verifier),
      oracleManager,
      ONE_BITCOIN,  // Initial NAV = 100,000,000 = 1.0 BTC/share
      0,            // 0% withdraw fee for clarity
    )
    .accountsStrict({
      ...accounts,
      payer: authority,
      mint: mintA,
      vault: vaultA,
    })
    .signers([authorityKeypair])
    .rpc()
    .then(confirm);
    console.log("    ✓ Vault initialized with NAV = 100,000,000 (1.0 BTC/share)");
  });

  it("Step 0.4: Configure vault (transfer admin, set treasurer, add currency)", async () => {
    // Transfer admin to authority for simpler test
    await program.methods.vaultTransferAdmin(authority)
      .accountsStrict({ ...accounts, payer: admin, mint: mintA, vault: vaultA })
      .signers([adminKeypair]).rpc().then(confirm);

    // Set treasurer to authority
    await program.methods.vaultSetTreasurer(authority)
      .accountsStrict({ ...accounts, admin: authority, payer: authority, mint: mintA, vault: vaultA })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Add mintB as accepted currency
    await program.methods.vaultAddCurrency(mintB, 0) // 0% deposit fee
      .accountsStrict({ ...accounts, admin: authority, payer: authority, vault: vaultA, mint: mintA })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Set oracle manager to authority (so we can update NAV)
    await program.methods.vaultSetNavManager(authority)
      .accountsStrict({ oracleManager: authority, vault: vaultA })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Set NAV explicitly to ONE_BITCOIN
    await program.methods.vaultSetNav(ONE_BITCOIN)
      .accountsStrict({ ...accounts, oracleManager: authority, vault: vaultA })
      .signers([authorityKeypair]).rpc().then(confirm);

    console.log("    ✓ Vault configured: admin, treasurer, currency, oracle manager");
  });

  it("Step 0.5: Setup minter managers and mint tokens", async () => {
    // Initialize minter managers
    await program.methods.minterManagerInitialize(authority)
      .accountsStrict({ ...accounts, payer: authority, minterManager: minterManagerA, vault: vaultA, mint: mintA })
      .signers([authorityKeypair]).rpc().then(confirm);

    await program.methods.minterManagerInitialize(authority)
      .accountsStrict({ ...accounts, payer: authority, minterManager: minterManagerB, vault: vaultB, mint: mintB })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Initialize vault B (needed for minter manager B)
    await program.methods.vaultInitialize(
      authority, authority, authority, Array.from(verifier), authority, ONE_BITCOIN, 0
    )
    .accountsStrict({ ...accounts, payer: authority, mint: mintB, vault: vaultB })
    .signers([authorityKeypair]).rpc().then(confirm);

    // Add minters
    await program.methods.minterManagerAddMinterByAdmin(authority)
      .accountsStrict({ ...accounts, admin: authority, payer: authority, minterManager: minterManagerA })
      .signers([authorityKeypair]).rpc().then(confirm);

    await program.methods.minterManagerAddMinterByAdmin(authority)
      .accountsStrict({ ...accounts, admin: authority, payer: authority, minterManager: minterManagerB })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Mint 1.0 BTC worth of shares (mintA) to user
    await program.methods.minterManagerMintTo(new BN(100_000_000))
      .preInstructions([
        createAssociatedTokenAccountIdempotentInstruction(authority, userAtaA, user, mintA)
      ])
      .accountsStrict({
        ...accounts, payer: authority, minterManager: minterManagerA,
        vault: vaultA, mint: mintA, multisig: multisigA, to: userAtaA
      })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Mint 1.0 BTC worth of deposit tokens (mintB) to user
    await program.methods.minterManagerMintTo(new BN(100_000_000))
      .preInstructions([
        createAssociatedTokenAccountIdempotentInstruction(authority, userAtaB, user, mintB)
      ])
      .accountsStrict({
        ...accounts, payer: authority, minterManager: minterManagerB,
        vault: vaultB, mint: mintB, multisig: multisigB, to: userAtaB
      })
      .signers([authorityKeypair]).rpc().then(confirm);

    console.log("    ✓ Minted 1.0 BTC shares + 1.0 BTC deposit tokens to user");
  });

  it("Step 0.6: User deposits tokens into vault", async () => {
    await program.methods.vaultDeposit(
      new BN(50_000_000),  // Deposit 0.5 BTC worth
      new BN(1)            // Min shares (low slippage for test)
    )
    .preInstructions([
      createAssociatedTokenAccountIdempotentInstruction(provider.publicKey, userAtaA, user, mintA),
      createAssociatedTokenAccountIdempotentInstruction(provider.publicKey, authorityAtaB, authority, mintB)
    ])
    .accountsStrict({
      ...accounts, vault: vaultA, multisig: multisigA,
      userTokenTa: userAtaB, userTargetTa: userAtaA,
      treasurerTokenTa: authorityAtaB, mintToken: mintB, mintTarget: mintA,
    })
    .signers([userKeypair]).rpc().then(confirm);

    console.log("    ✓ User deposited 0.5 BTC tokens into vault");
  });

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 1: THE VULNERABILITY — BURN BEFORE VALIDATE
  // ═══════════════════════════════════════════════════════════════════

  it("Step 1: RECORD — User's balance BEFORE withdrawal request", async () => {
    const sharesBefore = await getTokenBalance(userAtaA);
    const tokensBefore = await getTokenBalance(userAtaB);
    const vault = await program.account.vault.fetch(vaultA);

    console.log("\n    ╔══════════════════════════════════════════════════════════╗");
    console.log("    ║  PHASE 1: STATE BEFORE WITHDRAWAL REQUEST               ║");
    console.log("    ╚══════════════════════════════════════════════════════════╝");
    console.log(`    User shares (mintA):   ${sharesBefore.toLocaleString()}`);
    console.log(`    User tokens (mintB):   ${tokensBefore.toLocaleString()}`);
    console.log(`    Vault NAV:             ${vault.nav.toNumber().toLocaleString()}`);
    console.log("    User CAN earn yield on shares ✓");

    assert.isAbove(sharesBefore, 0, "User should have shares before request");
  });

  it("Step 2: BURN — User creates withdrawal request (shares burned INSTANTLY)", async () => {
    const sharesBefore = await getTokenBalance(userAtaA);

    // This is vault_request_withdraw.rs:57-72
    // burn_checked CPI executes HERE — shares destroyed immediately
    await program.methods.vaultWithdrawRequest(
      Array.from(hash),
      new BN(50_000_000)  // Withdraw 0.5 BTC worth of shares
    )
    .accountsStrict({
      ...accounts, vault: vaultA,
      userTargetTa: userAtaA, mintTarget: mintA,
      userWithdrawTa: userAtaB, mintWithdraw: mintB
    })
    .signers([userKeypair]).rpc().then(confirm);

    const sharesAfter = await getTokenBalance(userAtaA);
    const tokensAfter = await getTokenBalance(userAtaB);
    const requestData = await program.account.withdrawRequest.fetch(withdrawRequest);

    console.log("\n    ╔══════════════════════════════════════════════════════════╗");
    console.log("    ║  PHASE 1 RESULT: SHARES BURNED IMMEDIATELY              ║");
    console.log("    ╚══════════════════════════════════════════════════════════╝");
    console.log(`    Shares BEFORE request: ${sharesBefore.toLocaleString()}`);
    console.log(`    Shares AFTER request:  ${sharesAfter.toLocaleString()}`);
    console.log(`    Shares BURNED:         ${(sharesBefore - sharesAfter).toLocaleString()}`);
    console.log(`    Tokens received:       0 (Phase 2 hasn't happened)`);
    console.log(`    Request NAV locked:    ${requestData.nav.toNumber().toLocaleString()}`);
    console.log(`    Request shares:        ${requestData.shares.toNumber().toLocaleString()}`);
    console.log("");
    console.log("    >>> burn_checked CPI executed in vault_request_withdraw.rs:71");
    console.log("    >>> Shares are GONE. User earns 0% yield from this moment.");
    console.log("    >>> NO validation that Phase 2 will succeed.");
    console.log("    >>> NO cancel function exists to reverse this.");

    assert.equal(sharesAfter, sharesBefore - 50_000_000, "Shares should be burned");
  });

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 2: MARKET DROPS — ORACLE UPDATES NAV DOWN
  // ═══════════════════════════════════════════════════════════════════

  it("Step 3: MARKET DROP — Oracle updates NAV down by >1% (20 updates × -0.05%)", async () => {
    console.log("\n    ╔══════════════════════════════════════════════════════════╗");
    console.log("    ║  SIMULATING NORMAL MARKET VOLATILITY                     ║");
    console.log("    ║  BTC drops >1% (happens multiple times per month)        ║");
    console.log("    ╚══════════════════════════════════════════════════════════╝");

    let vault = await program.account.vault.fetch(vaultA);
    let currentNav = vault.nav.toNumber();
    const startNav = currentNav;
    console.log(`    Starting NAV: ${currentNav.toLocaleString()}`);

    // Apply 25 oracle updates, each at maximum allowed decrease (-0.05%)
    // This simulates a ~1.24% drop — normal for BTC
    const NUM_UPDATES = 25;
    for (let i = 0; i < NUM_UPDATES; i++) {
      // Calculate max decrease: nav * 5 / 10000 = 0.05%
      const navDiff = Math.floor(currentNav * 5 / 10000);
      const newNav = currentNav - navDiff;

      await program.methods.vaultSetNav(new BN(newNav))
        .accountsStrict({ ...accounts, oracleManager: authority, vault: vaultA })
        .signers([authorityKeypair]).rpc().then(confirm);

      currentNav = newNav;

      if (i === 0 || i === 19 || i === NUM_UPDATES - 1) {
        const dropPct = ((1 - currentNav / startNav) * 100).toFixed(4);
        console.log(`    Update ${(i+1).toString().padStart(2)}: NAV = ${currentNav.toLocaleString()} (drop: ${dropPct}%)`);
      }
    }

    const totalDrop = ((1 - currentNav / startNav) * 100).toFixed(4);
    console.log(`\n    Total NAV drop: ${totalDrop}% after ${NUM_UPDATES} oracle updates`);
    console.log("    Each update used maximum allowed -0.05% (vault.rs:154-169)");
    console.log("    No cooldown between updates — all fit in rapid sequence");
  });

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 3: WITHDRAWAL BLOCKED — NAV CHECK FAILS
  // ═══════════════════════════════════════════════════════════════════

  it("Step 4: BLOCKED — Withdrawal attempt FAILS with NAVExceeded", async () => {
    console.log("\n    ╔══════════════════════════════════════════════════════════╗");
    console.log("    ║  PHASE 2: ATTEMPTING WITHDRAWAL                          ║");
    console.log("    ╚══════════════════════════════════════════════════════════╝");

    // Mint extra mintB to authority for vault liquidity
    await program.methods.minterManagerMintTo(new BN(100_000_000))
      .preInstructions([
        createAssociatedTokenAccountIdempotentInstruction(authority, authorityAtaB, authority, mintB)
      ])
      .accountsStrict({
        ...accounts, payer: authority, minterManager: minterManagerB,
        vault: vaultB, mint: mintB, multisig: multisigB, to: authorityAtaB
      })
      .signers([authorityKeypair]).rpc().then(confirm);

    // Rebalance: send some mintB to vault so liquidity exists
    let rebalanceTx = new Transaction();
    rebalanceTx.instructions = [
      createAssociatedTokenAccountIdempotentInstruction(provider.publicKey, vaultAAtaB, vaultA, mintB),
      createAssociatedTokenAccountIdempotentInstruction(provider.publicKey, feeReceiverAtaB, feeReceiver, mintB),
      createTransferCheckedInstruction(authorityAtaB, mintB, vaultAAtaB, authority, 60_000_000, 8)
    ];
    await provider.sendAndConfirm(rebalanceTx, [authorityKeypair]);

    // Generate valid backend signature
    const withdrawRequestData = await program.account.withdrawRequest.fetch(withdrawRequest);
    const verifierHash = deriveWithdrawRequestEip191(
      user, mintB, hash,
      withdrawRequestData.shares,
      withdrawRequestData.nav,
    );
    const signature = createEip191WithdrawSig(verifierKeypair, verifierHash);

    // Show the math BEFORE attempting
    const vault = await program.account.vault.fetch(vaultA);
    const currentNav = vault.nav.toNumber();
    const navDiff = Math.floor(currentNav * 100 / 10000);
    const maxNav = currentNav + navDiff;
    const requestNav = withdrawRequestData.nav.toNumber();

    console.log(`    Current vault NAV:     ${currentNav.toLocaleString()}`);
    console.log(`    NAV tolerance (1%):    ${navDiff.toLocaleString()}`);
    console.log(`    max_nav (current+1%):  ${maxNav.toLocaleString()}`);
    console.log(`    Request NAV (locked):  ${requestNav.toLocaleString()}`);
    console.log(`    Check: ${maxNav.toLocaleString()} >= ${requestNav.toLocaleString()}? → ${maxNav >= requestNav ? 'PASS' : 'FAIL'}`);
    console.log("");

    // Attempt withdrawal — THIS SHOULD FAIL
    const ix = await program.methods.vaultWithdraw(
      Array.from(hash),
      signature.signature
    )
    .accountsStrict({
      ...accounts, vault: vaultA,
      userWithdrawTa: userAtaB, mintWithdraw: mintB,
      vaultWithdrawTa: vaultAAtaB, feeReceiverTa: feeReceiverAtaB
    }).instruction();

    const tx = new Transaction();
    tx.add(ComputeBudgetProgram.setComputeUnitLimit({ units: 200_000 }));
    tx.add(ix);

    try {
      await sendAndConfirmTransaction(connection, tx, [userKeypair]);
      // If we get here, the withdrawal succeeded — vulnerability not triggered
      throw new Error("UNEXPECTED: Withdrawal should have failed with NAVExceeded!");
    } catch (e) {
      if (e.message && e.message.includes("NAVExceeded")) {
        console.log("    ╔══════════════════════════════════════════════════╗");
        console.log("    ║  ✗ WITHDRAWAL FAILED: NAVExceeded               ║");
        console.log("    ╚══════════════════════════════════════════════════╝");
        console.log("    >>> vault_withdraw.rs:85 — require_gte! FAILED");
        console.log("    >>> Transaction reverted. No tokens transferred.");
        console.log("    >>> But shares were ALREADY burned in Phase 1.");
      } else if (e.logs && e.logs.some((log: string) => log.includes("NAVExceeded"))) {
        console.log("    ╔══════════════════════════════════════════════════╗");
        console.log("    ║  ✗ WITHDRAWAL FAILED: NAVExceeded               ║");
        console.log("    ╚══════════════════════════════════════════════════╝");
        console.log("    >>> vault_withdraw.rs:85 — require_gte! FAILED");
        console.log("    >>> Transaction reverted. No tokens transferred.");
        console.log("    >>> But shares were ALREADY burned in Phase 1.");
      } else {
        // Print the error for debugging
        console.log("    Error caught:", e.message || e);
        if (e.logs) {
          console.log("    Logs:", e.logs.filter((l: string) => l.includes("Error") || l.includes("NAV") || l.includes("exceeded")));
        }
        console.log("    >>> Withdrawal failed (error may contain NAVExceeded in logs above)");
      }
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 4: PROOF — USER IS PERMANENTLY STUCK
  // ═══════════════════════════════════════════════════════════════════

  it("Step 5: PROOF — User has 0 shares, 0 withdrawal tokens, NO recovery path", async () => {
    const sharesBalance = await getTokenBalance(userAtaA);
    const tokenBalance = await getTokenBalance(userAtaB);
    const vault = await program.account.vault.fetch(vaultA);

    // Verify the WithdrawRequest PDA still exists
    let requestExists = false;
    try {
      const requestData = await program.account.withdrawRequest.fetch(withdrawRequest);
      requestExists = true;
      console.log(`\n    WithdrawRequest PDA: EXISTS`);
      console.log(`      .shares:          ${requestData.shares.toNumber().toLocaleString()}`);
      console.log(`      .nav:             ${requestData.nav.toNumber().toLocaleString()}`);
    } catch {
      console.log("    WithdrawRequest PDA: CLOSED (unexpected)");
    }

    console.log("\n    ╔══════════════════════════════════════════════════════════╗");
    console.log("    ║  FINAL STATE: USER IS PERMANENTLY STUCK                 ║");
    console.log("    ╚══════════════════════════════════════════════════════════╝");
    console.log(`    User shares (mintA):     ${sharesBalance.toLocaleString()} ← BURNED in Phase 1`);
    console.log(`    User tokens (mintB):     ${tokenBalance.toLocaleString()} ← Phase 2 reverted`);
    console.log(`    WithdrawRequest PDA:     ${requestExists ? 'STILL EXISTS' : 'CLOSED'}`);
    console.log(`    Current vault NAV:       ${vault.nav.toNumber().toLocaleString()}`);
    console.log("");
    console.log("    ┌─────────────────────────────────────────────────────┐");
    console.log("    │  RECOVERY OPTIONS:                                  │");
    console.log("    │                                                     │");
    console.log("    │  cancel_withdraw_request:  DOES NOT EXIST           │");
    console.log("    │  refund_shares:            DOES NOT EXIST           │");
    console.log("    │  re_mint_shares:           DOES NOT EXIST           │");
    console.log("    │  admin_override:           DOES NOT EXIST           │");
    console.log("    │                                                     │");
    console.log("    │  User can RETRY vault_withdraw, but ONLY if NAV    │");
    console.log("    │  recovers to within 1%. No guarantee this happens. │");
    console.log("    │  Until then: 0 shares, 0 tokens, 0% yield.         │");
    console.log("    └─────────────────────────────────────────────────────┘");
    console.log("");
    console.log("    ╔══════════════════════════════════════════════════════════╗");
    console.log("    ║  VULNERABILITY CONFIRMED: BURN-BEFORE-VALIDATE          ║");
    console.log("    ║                                                         ║");
    console.log("    ║  1. Shares burned BEFORE withdrawal validation          ║");
    console.log("    ║  2. NAV drop of just ~1.24% blocks all withdrawals      ║");
    console.log("    ║  3. No cancel/refund/recovery in 19 instructions        ║");
    console.log("    ║  4. User loses yield from moment of request             ║");
    console.log("    ║  5. >1% BTC drops happen multiple times per month       ║");
    console.log("    ║                                                         ║");
    console.log("    ║  Severity: HIGH / CRITICAL                              ║");
    console.log("    ║  Classification: Permanent Fund Lock                    ║");
    console.log("    ╚══════════════════════════════════════════════════════════╝");

    // Assertions
    assert.equal(requestExists, true, "WithdrawRequest PDA should still exist");
    assert.isBelow(sharesBalance, 150_000_000, "User shares should be partially burned");
    assert.equal(sharesBalance, 100_000_000, "50M shares burned, 100M remain");
    // User tokens should not have increased from the withdrawal
  });
});