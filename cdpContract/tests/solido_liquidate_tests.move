#[test_only]
module cdp::cdp_multi_liquidate_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::timestamp;
    use supra_framework::account;
    use supra_framework::block;
    use cdp::cdp_multi::{Self, CASH};
    use cdp::price_oracle;
    use cdp::config;
    
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
    
    fun setup_low_precision_test(
        cdp_admin: &signer,
        borrower: &signer,
        liquidator: &signer
    ) acquires CoinCapabilities {
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        
        // Register accounts for coins
        cdp_multi::register_collateral_coin<LowPrecisionCoin>(borrower);
        cdp_multi::register_debtToken_coin(borrower);
        
        cdp_multi::register_collateral_coin<LowPrecisionCoin>(liquidator);
        cdp_multi::register_debtToken_coin(liquidator);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(cdp_admin));
        
        // Mint collateral to borrower (5 LPC with 6 decimals)
        coin::deposit(borrower_addr, coin::mint(5000000, &caps.low_precision_mint_cap));
        
        // Open trove for borrower
        cdp_multi::open_trove<LowPrecisionCoin>(borrower, 5000000, 200000000); // 5 LPC, 2 debtToken
        
        // Mint debtToken to liquidator
        cdp_multi::mint_debtToken_for_test(liquidator_addr, 400000000); // 4 debtToken
    }
    
    fun setup_standard_precision_test(
        cdp_admin: &signer,
        borrower: &signer,
        liquidator: &signer
    ) acquires CoinCapabilities {
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        
        // Register accounts for coins
        cdp_multi::register_collateral_coin<StandardCoin>(borrower);
        cdp_multi::register_debtToken_coin(borrower);
        
        cdp_multi::register_collateral_coin<StandardCoin>(liquidator);
        cdp_multi::register_debtToken_coin(liquidator);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(cdp_admin));
        
        // Mint collateral to borrower (5 STC with 8 decimals)
        coin::deposit(borrower_addr, coin::mint(500000000, &caps.standard_mint_cap));
        
        // Open trove for borrower
        cdp_multi::open_trove<StandardCoin>(borrower, 500000000, 200000000); // 5 STC, 2 debtToken
        
        // Mint debtToken to liquidator
        cdp_multi::mint_debtToken_for_test(liquidator_addr, 400000000); // 4 debtToken
    }
    
    fun setup_high_precision_test(
        cdp_admin: &signer,
        borrower: &signer,
        liquidator: &signer
    ) acquires CoinCapabilities {
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        
        // Register accounts for coins
        cdp_multi::register_collateral_coin<HighPrecisionCoin>(borrower);
        cdp_multi::register_debtToken_coin(borrower);
        
        cdp_multi::register_collateral_coin<HighPrecisionCoin>(liquidator);
        cdp_multi::register_debtToken_coin(liquidator);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(cdp_admin));
        
        // Mint collateral to borrower (5 HPC with 10 decimals)
        coin::deposit(borrower_addr, coin::mint(50000000000, &caps.high_precision_mint_cap));
        
        // Open trove for borrower
        cdp_multi::open_trove<HighPrecisionCoin>(borrower, 50000000000, 200000000); // 5 HPC, 2 debtToken
        
        // Mint debtToken to liquidator
        cdp_multi::mint_debtToken_for_test(liquidator_addr, 400000000); // 4 debtToken
    }
    
    #[test]
    fun test_liquidate_low_precision_coin() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let borrower = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Setup users with low precision coin
        setup_low_precision_test(&cdp_admin, &borrower, &liquidator);
        
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        
        // Verify initial position exists
        let (initial_collateral, initial_debt, exists) = cdp_multi::get_user_position<LowPrecisionCoin>(borrower_addr);
        assert!(exists, 101);
        assert!(initial_collateral > 0, 102);
        assert!(initial_debt > 0, 103);
        
        // Lower the price to make the position liquidatable (below 120% threshold)
        cdp_multi::set_price<LowPrecisionCoin>(&cdp_admin, 40000000); // 0.4 debtToken per LPC
        
        // Check liquidator's initial debtToken balance
        let liquidator_initial_debtToken = coin::balance<CASH>(liquidator_addr);
        
        // Liquidate the position
        cdp_multi::liquidate<LowPrecisionCoin>(&liquidator, borrower_addr);
        
        // Verify the position no longer exists
        let (_, _, exists_after) = cdp_multi::get_user_position<LowPrecisionCoin>(borrower_addr);
        assert!(!exists_after, 104);
        
        // Check that liquidator used debtToken
        let liquidator_final_debtToken = coin::balance<CASH>(liquidator_addr);
        let debtToken_spent = liquidator_initial_debtToken - liquidator_final_debtToken;
        
        // Liquidator should have spent around initial_debt
        assert!(debtToken_spent > 0, 105);
        
        // Verify liquidator received collateral
        let liquidator_collateral = coin::balance<LowPrecisionCoin>(liquidator_addr);
        assert!(liquidator_collateral > 0, 106);
    }
    
    #[test]
    fun test_liquidate_standard_precision_coin() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let borrower = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Setup users with standard precision coin
        setup_standard_precision_test(&cdp_admin, &borrower, &liquidator);
        
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        
        // Verify initial position exists
        let (initial_collateral, initial_debt, exists) = cdp_multi::get_user_position<StandardCoin>(borrower_addr);
        assert!(exists, 201);
        assert!(initial_collateral > 0, 202);
        assert!(initial_debt > 0, 203);
        
        // Lower the price to make the position liquidatable (below 120% threshold)
        cdp_multi::set_price<StandardCoin>(&cdp_admin, 40000000); // 0.4 debtToken per STC
        
        // Check liquidator's initial debtToken balance
        let liquidator_initial_debtToken = coin::balance<CASH>(liquidator_addr);
        
        // Liquidate the position
        cdp_multi::liquidate<StandardCoin>(&liquidator, borrower_addr);
        
        // Verify the position no longer exists
        let (_, _, exists_after) = cdp_multi::get_user_position<StandardCoin>(borrower_addr);
        assert!(!exists_after, 204);
        
        // Check that liquidator used debtToken
        let liquidator_final_debtToken = coin::balance<CASH>(liquidator_addr);
        let debtToken_spent = liquidator_initial_debtToken - liquidator_final_debtToken;
        
        // Liquidator should have spent around initial_debt
        assert!(debtToken_spent > 0, 205);
        
        // Verify liquidator received collateral
        let liquidator_collateral = coin::balance<StandardCoin>(liquidator_addr);
        assert!(liquidator_collateral > 0, 206);
    }
    
    #[test]
    fun test_liquidate_high_precision_coin() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let borrower = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Setup users with high precision coin
        setup_high_precision_test(&cdp_admin, &borrower, &liquidator);
        
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        
        // Verify initial position exists
        let (initial_collateral, initial_debt, exists) = cdp_multi::get_user_position<HighPrecisionCoin>(borrower_addr);
        assert!(exists, 301);
        assert!(initial_collateral > 0, 302);
        assert!(initial_debt > 0, 303);
        
        // Lower the price to make the position liquidatable (below 120% threshold)
        cdp_multi::set_price<HighPrecisionCoin>(&cdp_admin, 40000000); // 0.4 debtToken per HPC
        
        // Check liquidator's initial debtToken balance
        let liquidator_initial_debtToken = coin::balance<CASH>(liquidator_addr);
        
        // Liquidate the position
        cdp_multi::liquidate<HighPrecisionCoin>(&liquidator, borrower_addr);
        
        // Verify the position no longer exists
        let (_, _, exists_after) = cdp_multi::get_user_position<HighPrecisionCoin>(borrower_addr);
        assert!(!exists_after, 304);
        
        // Check that liquidator used debtToken
        let liquidator_final_debtToken = coin::balance<CASH>(liquidator_addr);
        let debtToken_spent = liquidator_initial_debtToken - liquidator_final_debtToken;
        
        // Liquidator should have spent around initial_debt
        assert!(debtToken_spent > 0, 305);
        
        // Verify liquidator received collateral
        let liquidator_collateral = coin::balance<HighPrecisionCoin>(liquidator_addr);
        assert!(liquidator_collateral > 0, 306);
    }
    
    #[test]
    fun test_liquidate_different_icr_levels() acquires CoinCapabilities {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        
        // Create borrowers at different ICR levels
        let borrower1 = account::create_account_for_test(@0x123); // ICR < 100%
        let borrower2 = account::create_account_for_test(@0x234); // 100% < ICR < 110%
        let borrower3 = account::create_account_for_test(@0x345); // ICR > 110%
        
        let liquidator = account::create_account_for_test(@0x456);
        
        // Initialize environment
        setup_environment(&aptos_framework, &cdp_admin);
        
        // Register all users
        cdp_multi::register_collateral_coin<StandardCoin>(&borrower1);
        cdp_multi::register_collateral_coin<StandardCoin>(&borrower2);
        cdp_multi::register_collateral_coin<StandardCoin>(&borrower3);
        cdp_multi::register_collateral_coin<StandardCoin>(&liquidator);
        
        cdp_multi::register_debtToken_coin(&borrower1);
        cdp_multi::register_debtToken_coin(&borrower2);
        cdp_multi::register_debtToken_coin(&borrower3);
        cdp_multi::register_debtToken_coin(&liquidator);
        
        // Get mint capability
        let caps = borrow_global<CoinCapabilities>(signer::address_of(&cdp_admin));
        
        // Mint collateral to borrowers
        coin::deposit(signer::address_of(&borrower1), coin::mint(500000000, &caps.standard_mint_cap)); // 5 STC
        coin::deposit(signer::address_of(&borrower2), coin::mint(500000000, &caps.standard_mint_cap)); // 5 STC
        coin::deposit(signer::address_of(&borrower3), coin::mint(500000000, &caps.standard_mint_cap)); // 5 STC
        
        // Open troves for all borrowers
        cdp_multi::open_trove<StandardCoin>(&borrower1, 500000000, 200000000); // 5 STC, 2 debtToken
        cdp_multi::open_trove<StandardCoin>(&borrower2, 500000000, 200000000); // 5 STC, 2 debtToken
        cdp_multi::open_trove<StandardCoin>(&borrower3, 500000000, 200000000); // 5 STC, 2 debtToken
        
        // Mint debtToken to liquidator for liquidations
        cdp_multi::mint_debtToken_for_test(signer::address_of(&liquidator), 1000000000); // 10 debtToken
        
        // Set different prices to create three ICR scenarios
        
        // 1. ICR < 100% (severe undercollateralization)
        // For borrower1: Collateral = 5 STC, Debt ~= 2.1 debtToken (with fees)
        // At price 0.3 debtToken per STC: Collateral value = 1.5 debtToken
        // ICR = 1.5/2.1 * 100% = ~71%
        cdp_multi::set_price<StandardCoin>(&cdp_admin, 30000000); // 0.3 debtToken per STC
        cdp_multi::liquidate<StandardCoin>(&liquidator, signer::address_of(&borrower1));
        
        // 2. 100% < ICR < 110% (moderate undercollateralization)
        // For borrower2: Collateral = 5 STC, Debt ~= 2.1 debtToken (with fees)
        // At price 0.45 debtToken per STC: Collateral value = 2.25 debtToken
        // ICR = 2.25/2.1 * 100% = ~107%
        cdp_multi::set_price<StandardCoin>(&cdp_admin, 45000000); // 0.45 debtToken per STC
        cdp_multi::liquidate<StandardCoin>(&liquidator, signer::address_of(&borrower2));
        
        // 3. ICR > 110% (above liquidation penalty, but still below threshold)
        // For borrower3: Collateral = 5 STC, Debt ~= 2.1 debtToken (with fees)
        // At price 0.5 debtToken per STC: Collateral value = 2.5 debtToken
        // ICR = 2.5/2.1 * 100% = ~119%
        cdp_multi::set_price<StandardCoin>(&cdp_admin, 50000000); // 0.5 debtToken per STC
        cdp_multi::liquidate<StandardCoin>(&liquidator, signer::address_of(&borrower3));
        
        // After all liquidations, all positions should be gone
        let (_, _, exists1) = cdp_multi::get_user_position<StandardCoin>(signer::address_of(&borrower1));
        let (_, _, exists2) = cdp_multi::get_user_position<StandardCoin>(signer::address_of(&borrower2));
        let (_, _, exists3) = cdp_multi::get_user_position<StandardCoin>(signer::address_of(&borrower3));
        
        assert!(!exists1, 401);
        assert!(!exists2, 402);
        assert!(!exists3, 403);
        
        // Verify final collateral balance of liquidator - should have acquired collateral
        // in all three cases
        let liquidator_collateral = coin::balance<StandardCoin>(signer::address_of(&liquidator));
        assert!(liquidator_collateral > 0, 404);
    }
}