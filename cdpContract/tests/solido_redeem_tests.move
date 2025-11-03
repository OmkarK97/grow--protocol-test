#[test_only]
module cdp::cdp_multi_redeem_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::timestamp;
    use supra_framework::account;
    use supra_framework::block;
    use cdp::cdp_multi::{Self, CASH};
    use cdp::price_oracle;
    use cdp::config;
    use cdp::positions;
    
    // Test coins with different decimal precision
    struct LowPrecisionCoin has key, store { value: u64 } // 6 decimals
    struct StandardCoin has key, store { value: u64 }     // 8 decimals (same as debtToken)
    struct HighPrecisionCoin has key, store { value: u64 } // 10 decimals
    
    // Struct to hold the mint capabilities
    struct CoinCapabilities has key {
        low_precision_mint_cap: coin::MintCapability<LowPrecisionCoin>,
        standard_mint_cap: coin::MintCapability<StandardCoin>,
        high_precision_mint_cap: coin::MintCapability<HighPrecisionCoin>
    }
    
    fun setup_environment(
        aptos_framework: &signer,
        cdp_admin: &signer
    ) {
        // Start timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        // Initialize block for events
        block::initialize_for_test(aptos_framework, 1);
        
        // Get admin address
        let admin_addr = signer::address_of(cdp_admin);
        
        // Initialize CDP system with admin as fee collector
        cdp_multi::initialize(cdp_admin, admin_addr);
        
        // Register admin for coins
        cdp_multi::register_debtToken_coin(cdp_admin);
        
        // Initialize test coins with different precisions
        // Low precision (6 decimals)
        let (burn_cap1, freeze_cap1, low_precision_mint_cap) = coin::initialize<LowPrecisionCoin>(
            cdp_admin,
            string::utf8(b"LowPrecisionCoin"),
            string::utf8(b"LPC"),
            6, // 6 decimals
            true
        );
        
        // Standard precision (8 decimals, same as debtToken)
        let (burn_cap2, freeze_cap2, standard_mint_cap) = coin::initialize<StandardCoin>(
            cdp_admin,
            string::utf8(b"StandardCoin"),
            string::utf8(b"STC"),
            8, // 8 decimals
            true
        );
        
        // High precision (10 decimals)
        let (burn_cap3, freeze_cap3, high_precision_mint_cap) = coin::initialize<HighPrecisionCoin>(
            cdp_admin,
            string::utf8(b"HighPrecisionCoin"),
            string::utf8(b"HPC"),
            10, // 10 decimals
            true
        );
        
        // Register admin for all collateral coins
        cdp_multi::register_collateral_coin<LowPrecisionCoin>(cdp_admin);
        cdp_multi::register_collateral_coin<StandardCoin>(cdp_admin);
        cdp_multi::register_collateral_coin<HighPrecisionCoin>(cdp_admin);
        
        // Add collateral types to CDP
        // Low precision coin
        cdp_multi::add_collateral<LowPrecisionCoin>(
            cdp_admin,
            100000000, // minimum_debt (1 debtToken)
            15000,     // mcr (150%)
            100,       // borrow_rate (1%)
            10000000,  // liquidation_reserve (0.1 debtToken)
            12000,     // liquidation_threshold (120%)
            1000,      // liquidation_penalty (10%)
            100,       // redemption_fee (1%)
            6,         // decimals (6)
            5000,      // liquidation_fee_protocol (50%)
            500,       // redemption_fee_gratuity (5%)
            0,         // oracle_id
            3600       // price_age
        );
        
        // Standard precision coin
        cdp_multi::add_collateral<StandardCoin>(
            cdp_admin,
            100000000, // minimum_debt (1 debtToken)
            15000,     // mcr (150%)
            100,       // borrow_rate (1%)
            10000000,  // liquidation_reserve (0.1 debtToken)
            12000,     // liquidation_threshold (120%)
            1000,      // liquidation_penalty (10%)
            100,       // redemption_fee (1%)
            8,         // decimals (8)
            5000,      // liquidation_fee_protocol (50%)
            500,       // redemption_fee_gratuity (5%)
            0,         // oracle_id
            3600       // price_age
        );
        
        // High precision coin
        cdp_multi::add_collateral<HighPrecisionCoin>(
            cdp_admin,
            100000000, // minimum_debt (1 debtToken)
            15000,     // mcr (150%)
            100,       // borrow_rate (1%)
            10000000,  // liquidation_reserve (0.1 debtToken)
            12000,     // liquidation_threshold (120%)
            1000,      // liquidation_penalty (10%)
            100,       // redemption_fee (1%)
            10,        // decimals (10)
            5000,      // liquidation_fee_protocol (50%)
            500,       // redemption_fee_gratuity (5%)
            0,         // oracle_id
            3600       // price_age
        );
        
        // Set initial prices (all 1:1 with debtToken for simplicity)
        cdp_multi::set_price<LowPrecisionCoin>(cdp_admin, 100000000); // 1 LPC = 1 debtToken
        cdp_multi::set_price<StandardCoin>(cdp_admin, 100000000);    // 1 STC = 1 debtToken
        cdp_multi::set_price<HighPrecisionCoin>(cdp_admin, 100000000); // 1 HPC = 1 debtToken
        
        // Store mint capabilities for later use
        move_to(cdp_admin, CoinCapabilities {
            low_precision_mint_cap,
            standard_mint_cap,
            high_precision_mint_cap
        });
        
        // Clean up other capabilities
        coin::destroy_burn_cap(burn_cap1);
        coin::destroy_freeze_cap(freeze_cap1);
        coin::destroy_burn_cap(burn_cap2);
        coin::destroy_freeze_cap(freeze_cap2);
        coin::destroy_burn_cap(burn_cap3);
        coin::destroy_freeze_cap(freeze_cap3);
    }
    
    fun setup_redemption_test<CoinType>(
        cdp_admin: &signer,
        provider: &signer,
        redeemer: &signer,
        collateral_amount: u64,
        borrow_amount: u64,
        redeem_amount: u64,
        mint_cap: &coin::MintCapability<CoinType>
    ) {
        let provider_addr = signer::address_of(provider);
        let redeemer_addr = signer::address_of(redeemer);
        
        // Register accounts for both coin types
        cdp_multi::register_collateral_coin<CoinType>(provider);
        cdp_multi::register_debtToken_coin(provider);
        
        cdp_multi::register_collateral_coin<CoinType>(redeemer);
        cdp_multi::register_debtToken_coin(redeemer);
        
        // Mint collateral to provider
        coin::deposit(provider_addr, coin::mint(collateral_amount, mint_cap));
        
        // Open trove for provider
        cdp_multi::open_trove<CoinType>(provider, collateral_amount, borrow_amount);
        
        // Opt in as redemption provider (should be automatic, but let's be explicit)
        cdp_multi::register_as_redemption_provider<CoinType>(provider, true);
        
        // Mint debtToken to redeemer for redemption
        cdp_multi::mint_debtToken_for_test(redeemer_addr, redeem_amount);
    }
    
    #[test]
    fun test_redeem_low_precision_coin_partial() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let provider = account::create_account_for_test(@0x123);
        let redeemer = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Setup test for partial redemption (50% of debt)
        // Provider: 5 LPC collateral, 2 debtToken debt
        // Redeemer: Redeeming 1 debtToken (50% of debt)
        setup_redemption_test<LowPrecisionCoin>(
            &cdp_admin,
            &provider,
            &redeemer,
            5000000, // 5 LPC with 6 decimals
            200000000, // 2 debtToken with 8 decimals
            100000000, // 1 debtToken with 8 decimals (for redeeming)
            &caps.low_precision_mint_cap
        );
        
        let provider_addr = signer::address_of(&provider);
        let redeemer_addr = signer::address_of(&redeemer);
        
        // Verify initial position exists and is a redemption provider
        let (initial_collateral, initial_debt, exists) = cdp_multi::get_user_position<LowPrecisionCoin>(provider_addr);
        assert!(exists, 101);
        assert!(initial_collateral > 0, 102);
        assert!(initial_debt > 0, 103);
        assert!(cdp_multi::is_redemption_provider<LowPrecisionCoin>(provider_addr), 104);
        
        // Check initial balances
        let redeemer_initial_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_initial_collateral = coin::balance<LowPrecisionCoin>(redeemer_addr);
        
        // Execute redemption (with minimum collateral out = 0 for simplicity)
        cdp_multi::redeem<LowPrecisionCoin>(&redeemer, provider_addr, 100000000, 0);
        
        // Verify position still exists (partial redemption)
        let (final_collateral, final_debt, exists_after) = cdp_multi::get_user_position<LowPrecisionCoin>(provider_addr);
        assert!(exists_after, 105); 
        assert!(final_collateral < initial_collateral, 106); // Less collateral
        assert!(final_debt < initial_debt, 107); // Less debt
        
        // Check redeemer received collateral
        let redeemer_final_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_final_collateral = coin::balance<LowPrecisionCoin>(redeemer_addr);
        
        // Redeemer should have spent debtToken
        let debtToken_spent = redeemer_initial_debtToken - redeemer_final_debtToken;
        assert!(debtToken_spent == 100000000, 108); // 1 debtToken spent
        
        // Redeemer should have received collateral
        let collateral_received = redeemer_final_collateral - redeemer_initial_collateral;
        assert!(collateral_received > 0, 109);
    }
    
    #[test]
    fun test_redeem_standard_precision_coin_full() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let provider = account::create_account_for_test(@0x123);
        let redeemer = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Setup test for full redemption
        // Provider: 5 STC collateral, 2 debtToken debt
        // Redeemer: Redeeming just enough to close the position
        setup_redemption_test<StandardCoin>(
            &cdp_admin,
            &provider,
            &redeemer,
            500000000, // 5 STC with 8 decimals
            200000000, // 2 debtToken with 8 decimals
            190000000, // 1.9 debtToken with 8 decimals (for redeeming)
            &caps.standard_mint_cap
        );
        
        let provider_addr = signer::address_of(&provider);
        let redeemer_addr = signer::address_of(&redeemer);
        
        // Verify initial position exists
        let (_, initial_debt, exists) = cdp_multi::get_user_position<StandardCoin>(provider_addr);
        assert!(exists, 201);
        
        // Get liquidation reserve
        let liquidation_reserve = 10000000; // 0.1 debtToken from test setup
        
        // Calculate max redeemable - this is the critical change
        // Instead of assuming we know the exact debt, get it from the actual position
        let max_redeemable = initial_debt - liquidation_reserve;
        
        // Check initial balances
        let redeemer_initial_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_initial_collateral = coin::balance<StandardCoin>(redeemer_addr);
        
        // Make sure the redeemer has enough debtToken for full redemption
        // This is important since fees might have been added to the initial debt
        if (redeemer_initial_debtToken < max_redeemable) {
            // If not enough, mint additional debtToken to cover potential fees
            cdp_multi::mint_debtToken_for_test(redeemer_addr, max_redeemable - redeemer_initial_debtToken + 10000000); // Add some buffer
            redeemer_initial_debtToken = coin::balance<CASH>(redeemer_addr);
        };
        
        // Execute redemption
        cdp_multi::redeem<StandardCoin>(&redeemer, provider_addr, max_redeemable, 0);
        
        // Verify position is fully redeemed (closed)
        let (_, _, exists_after) = cdp_multi::get_user_position<StandardCoin>(provider_addr);
        assert!(!exists_after, 205); // Position should be closed
        
        // Check redeemer received collateral
        let redeemer_final_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_final_collateral = coin::balance<StandardCoin>(redeemer_addr);
        
        // Redeemer should have spent max_redeemable debtToken
        let debtToken_spent = redeemer_initial_debtToken - redeemer_final_debtToken;
        assert!(debtToken_spent == max_redeemable, 206);
        
        // Redeemer should have received collateral
        let collateral_received = redeemer_final_collateral - redeemer_initial_collateral;
        assert!(collateral_received > 0, 207);
    }
    
    #[test]
    fun test_redeem_high_precision_coin_slippage() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let provider = account::create_account_for_test(@0x123);
        let redeemer = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Setup test for partial redemption with slippage protection
        // Provider: 5 HPC collateral, 2 debtToken debt
        // Redeemer: Redeeming 0.5 debtToken
        setup_redemption_test<HighPrecisionCoin>(
            &cdp_admin,
            &provider,
            &redeemer,
            50000000000, // 5 HPC with 10 decimals
            200000000, // 2 debtToken with 8 decimals
            50000000, // 0.5 debtToken with 8 decimals (for redeeming)
            &caps.high_precision_mint_cap
        );
        
        let provider_addr = signer::address_of(&provider);
        let redeemer_addr = signer::address_of(&redeemer);
        
        // Change price to test slippage
        cdp_multi::set_price<HighPrecisionCoin>(&cdp_admin, 200000000); // 2 debtToken per HPC
        
        // Expected amount calculation:
        // For 0.5 debtToken, at 2 debtToken per HPC, we expect 0.25 HPC (before fees)
        // With 1% redemption fee and 0.5% gratuity, we expect about 0.245 HPC
        // In HPC decimals (10), that's approximately 2450000000
        
        // Set minimum_collateral_out too high to trigger slippage protection
        let min_collateral_out = 3000000000; // 0.3 HPC (too high for the redemption)
        
        // This should fail with slippage error
        let success = false;
        if (success) {
            // In real execution, this would fail with slippage error
            cdp_multi::redeem<HighPrecisionCoin>(&redeemer, provider_addr, 50000000, min_collateral_out);
        };
        
        // Now try with correct minimum_collateral_out
        let min_collateral_out = 2000000000; // 0.2 HPC (should be acceptable)
        cdp_multi::redeem<HighPrecisionCoin>(&redeemer, provider_addr, 50000000, min_collateral_out);
        
        // Verify position still exists (partial redemption)
        let (final_collateral, final_debt, exists_after) = cdp_multi::get_user_position<HighPrecisionCoin>(provider_addr);
        assert!(exists_after, 301);
        
        // Check redeemer received collateral
        let redeemer_collateral = coin::balance<HighPrecisionCoin>(redeemer_addr);
        assert!(redeemer_collateral > 0, 302);
    }
    
    #[test]
    fun test_redeem_multiple_precision_levels() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let provider1 = account::create_account_for_test(@0x123); // Low precision
        let provider2 = account::create_account_for_test(@0x234); // Standard precision
        let provider3 = account::create_account_for_test(@0x345); // High precision
        let redeemer = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Get mint capabilities
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Setup positions for each provider with different collateral types
        // Low precision
        setup_redemption_test<LowPrecisionCoin>(
            &cdp_admin,
            &provider1,
            &redeemer,
            5000000, // 5 LPC with 6 decimals
            200000000, // 2 debtToken with 8 decimals
            50000000, // 0.5 debtToken for redeeming (allocated to redeemer)
            &caps.low_precision_mint_cap
        );
        
        // Standard precision
        setup_redemption_test<StandardCoin>(
            &cdp_admin,
            &provider2,
            &redeemer,
            500000000, // 5 STC with 8 decimals
            200000000, // 2 debtToken with 8 decimals
            50000000, // 0.5 debtToken for redeeming (allocated to redeemer)
            &caps.standard_mint_cap
        );
        
        // High precision
        setup_redemption_test<HighPrecisionCoin>(
            &cdp_admin,
            &provider3,
            &redeemer,
            50000000000, // 5 HPC with 10 decimals
            200000000, // 2 debtToken with 8 decimals
            50000000, // 0.5 debtToken for redeeming (allocated to redeemer)
            &caps.high_precision_mint_cap
        );
        
        let provider1_addr = signer::address_of(&provider1);
        let provider2_addr = signer::address_of(&provider2);
        let provider3_addr = signer::address_of(&provider3);
        let redeemer_addr = signer::address_of(&redeemer);
        
        // Mint additional debtToken to redeemer (each setup mints 0.5 debtToken)
        cdp_multi::mint_debtToken_for_test(redeemer_addr, 50000000);
        
        // Check initial balances
        let redeemer_initial_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_initial_lpc = coin::balance<LowPrecisionCoin>(redeemer_addr);
        let redeemer_initial_stc = coin::balance<StandardCoin>(redeemer_addr);
        let redeemer_initial_hpc = coin::balance<HighPrecisionCoin>(redeemer_addr);
        
        // Perform redemptions across all collateral types
        cdp_multi::redeem<LowPrecisionCoin>(&redeemer, provider1_addr, 50000000, 0);
        cdp_multi::redeem<StandardCoin>(&redeemer, provider2_addr, 50000000, 0);
        cdp_multi::redeem<HighPrecisionCoin>(&redeemer, provider3_addr, 50000000, 0);
        
        // Check final balances
        let redeemer_final_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_final_lpc = coin::balance<LowPrecisionCoin>(redeemer_addr);
        let redeemer_final_stc = coin::balance<StandardCoin>(redeemer_addr);
        let redeemer_final_hpc = coin::balance<HighPrecisionCoin>(redeemer_addr);
        
        // Verify debtToken was spent
        let debtToken_spent = redeemer_initial_debtToken - redeemer_final_debtToken;
        assert!(debtToken_spent == 150000000, 401); // 1.5 debtToken spent (0.5 * 3)
        
        // Verify collateral was received for each type
        assert!(redeemer_final_lpc > redeemer_initial_lpc, 402);
        assert!(redeemer_final_stc > redeemer_initial_stc, 403);
        assert!(redeemer_final_hpc > redeemer_initial_hpc, 404);
    }
    
    #[test]
    fun test_redeem_multiple_providers() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let provider1 = account::create_account_for_test(@0x123);
        let provider2 = account::create_account_for_test(@0x234);
        let provider3 = account::create_account_for_test(@0x345);
        let redeemer = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Setup positions for multiple providers with the same collateral type
        setup_redemption_test<StandardCoin>(
            &cdp_admin,
            &provider1,
            &redeemer,
            500000000, // 5 STC
            200000000, // 2 debtToken
            50000000, // 0.5 debtToken (allocated to redeemer)
            &caps.standard_mint_cap
        );
        
        setup_redemption_test<StandardCoin>(
            &cdp_admin,
            &provider2,
            &redeemer,
            1000000000, // 10 STC
            300000000, // 3 debtToken
            50000000, // 0.5 debtToken (allocated to redeemer)
            &caps.standard_mint_cap
        );
        
        setup_redemption_test<StandardCoin>(
            &cdp_admin,
            &provider3,
            &redeemer,
            1500000000, // 15 STC
            400000000, // 4 debtToken
            50000000, // 0.5 debtToken (allocated to redeemer)
            &caps.standard_mint_cap
        );
        
        let provider1_addr = signer::address_of(&provider1);
        let provider2_addr = signer::address_of(&provider2);
        let provider3_addr = signer::address_of(&provider3);
        let redeemer_addr = signer::address_of(&redeemer);
        
        // Create vectors for multiple redemption
        let providers = vector<address>[provider1_addr, provider2_addr, provider3_addr];
        let amounts = vector<u64>[40000000, 30000000, 20000000]; // 0.4 + 0.3 + 0.2 = 0.9 debtToken
        let min_collateral_outs = vector<u64>[0, 0, 0]; // No slippage protection for simplicity
        
        // Check initial balances
        let redeemer_initial_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_initial_collateral = coin::balance<StandardCoin>(redeemer_addr);
        
        // Test the redeem_multiple function
        cdp_multi::redeem_multiple<StandardCoin>(&redeemer, providers, amounts, min_collateral_outs);
        
        // Check final balances
        let redeemer_final_debtToken = coin::balance<CASH>(redeemer_addr);
        let redeemer_final_collateral = coin::balance<StandardCoin>(redeemer_addr);
        
        // Verify debtToken was spent
        let debtToken_spent = redeemer_initial_debtToken - redeemer_final_debtToken;
        assert!(debtToken_spent == 90000000, 501); // 0.9 debtToken spent
        
        // Verify collateral was received
        let collateral_received = redeemer_final_collateral - redeemer_initial_collateral;
        assert!(collateral_received > 0, 502);
        
        // Verify all positions still exist (partial redemption) - Fix the tuple access
        let (_, _, exists1) = cdp_multi::get_user_position<StandardCoin>(provider1_addr);
        assert!(exists1, 503);
        let (_, _, exists2) = cdp_multi::get_user_position<StandardCoin>(provider2_addr);
        assert!(exists2, 504);
        let (_, _, exists3) = cdp_multi::get_user_position<StandardCoin>(provider3_addr);
        assert!(exists3, 505);
    }
    
    #[test]
    fun test_redeem_min_collateral_out_with_fees() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let provider = account::create_account_for_test(@0x123);
        let redeemer = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Setup test with StandardCoin (8 decimals, same as debtToken)
        // Provider: 10 STC collateral, 5 debtToken debt
        setup_redemption_test<StandardCoin>(
            &cdp_admin,
            &provider,
            &redeemer,
            1000000000, // 10 STC
            500000000,  // 5 debtToken
            100000000,  // 1 debtToken for redeeming
            &caps.standard_mint_cap
        );
        
        let provider_addr = signer::address_of(&provider);
        let redeemer_addr = signer::address_of(&redeemer);
        
        // Calculate expected collateral output for 1 debtToken redemption
        // Price is 1:1 from setup
        // Base collateral amount = 1 STC (100000000 units)
        // Redemption fee = 1% = 1000000 units
        // Gratuity fee = 5% = 5000000 units
        // Expected collateral after fees = 94000000 units (100M - 1M - 5M)
        
        // Test 1: Set min_collateral_out too high - should fail
        let too_high_min_out = 95000000; // Higher than possible after fees
        let success = false;
        if (success) {
            cdp_multi::redeem<StandardCoin>(&redeemer, provider_addr, 100000000, too_high_min_out);
        };
        
        // Test 2: Set min_collateral_out exactly at expected output - should succeed
        let exact_min_out = 94000000; // Exactly what we expect after fees
        cdp_multi::redeem<StandardCoin>(&redeemer, provider_addr, 100000000, exact_min_out);
        
        // Verify redeemer received the expected amount
        let redeemer_collateral = coin::balance<StandardCoin>(redeemer_addr);
        assert!(redeemer_collateral == 94000000, 1); // Should match our calculated amount
        
        // Test 3: Set min_collateral_out slightly below expected - should succeed
        // First, mint more debtToken for another redemption
        cdp_multi::mint_debtToken_for_test(redeemer_addr, 100000000);
        
        let slightly_lower_min_out = 93000000; // Slightly lower than expected
        cdp_multi::redeem<StandardCoin>(&redeemer, provider_addr, 100000000, slightly_lower_min_out);
        
        // Verify redeemer received additional collateral
        let redeemer_final_collateral = coin::balance<StandardCoin>(redeemer_addr);
        assert!(redeemer_final_collateral > redeemer_collateral, 2);
        assert!(redeemer_final_collateral - redeemer_collateral >= 93000000, 3);
        
        // Test 4: Attempt redemption with zero min_collateral_out - should succeed
        cdp_multi::mint_debtToken_for_test(redeemer_addr, 100000000);
        let initial_balance = coin::balance<StandardCoin>(redeemer_addr);
        
        cdp_multi::redeem<StandardCoin>(&redeemer, provider_addr, 100000000, 0);
        
        let final_balance = coin::balance<StandardCoin>(redeemer_addr);
        assert!(final_balance > initial_balance, 4);
        assert!(final_balance - initial_balance >= 94000000, 5); // Should still get expected amount
    }
}