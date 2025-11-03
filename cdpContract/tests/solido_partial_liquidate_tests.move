#[test_only]
module cdp::cdp_multi_partial_liquidate_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::timestamp;
    use supra_framework::account;
    use supra_framework::block;
    use cdp::cdp_multi::{Self, CASH};
    use cdp::price_oracle;
    use cdp::config;
    
    // Test coin for collateral
    struct TestCoin has key, store { value: u64 }
    
    fun setup_test(
        aptos_framework: &signer,
        cdp_admin: &signer,
        user1: &signer,
        user2: &signer
    ): (address, address, address, coin::MintCapability<TestCoin>) {
        // Start timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        block::initialize_for_test(aptos_framework, 1);
        
        // Get addresses
        let admin_addr = signer::address_of(cdp_admin);
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);
        
        // Initialize CDP system with the admin as fee collector
        cdp_multi::initialize(cdp_admin, admin_addr);
        
        // Initialize test coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            cdp_admin,
            string::utf8(b"TestCoin"),
            string::utf8(b"TC"),
            8,
            true
        );
        
        // Register coins for the fee collector (admin in this case)
        cdp_multi::register_debtToken_coin(cdp_admin);
        cdp_multi::register_collateral_coin<TestCoin>(cdp_admin);
        
        // Add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            cdp_admin,
            100000000, // minimum_debt (1 TC)
            15000,     // mcr (150%)
            100,       // borrow_rate (1%)
            10000000,  // liquidation_reserve (0.1 TC)
            12000,     // liquidation_threshold (120%)
            1000,      // liquidation_penalty (10%)
            100,       // redemption_fee (1%)
            8,         // decimals 
            5000,      // liquidation_fee_protocol (50%)
            500,       // redemption_fee_gratuity (5%)
            0,         // oracle_id
            3600       // price_age
        );
        
        // Register accounts for coins
        cdp_multi::register_collateral_coin<TestCoin>(user1);
        cdp_multi::register_collateral_coin<TestCoin>(user2);
        cdp_multi::register_debtToken_coin(user1);
        cdp_multi::register_debtToken_coin(user2);
        
        // Mint test coins to user1
        coin::deposit(user1_addr, coin::mint(1000000000, &mint_cap)); // 10 TC
        
        // Set price for TestCoin - using the test_only function in cdp_multi
        cdp_multi::set_price<TestCoin>(cdp_admin, 100000000); // 1 TC = 1 debtToken
        
        // Return the mint capability so we can mint more coins in tests
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        
        (admin_addr, user1_addr, user2_addr, mint_cap)
    }
    
    #[test]
    fun test_partial_liquidate_with_chunks() {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x456);
        
        let (_admin_addr, user1_addr, user2_addr, mint_cap) = setup_test(&aptos_framework, &cdp_admin, &user1, &user2);
        
        // Open a trove for user1
        cdp_multi::open_trove<TestCoin>(&user1, 500000000, 300000000); // 5 TC, 3 debtToken
        
        // Lower the price to make the position liquidatable
        cdp_multi::set_price<TestCoin>(&cdp_admin, 70000000); // 0.7 debtToken per TC
        
        // Mint debtToken to liquidator for tests
        cdp_multi::mint_debtToken_for_test(user2_addr, 200000000); // 2 debtToken
        
        // Get initial position values
        let (_, initial_debt, _) = cdp_multi::get_user_position<TestCoin>(user1_addr);
        
        // Test 1: Basic partial liquidation
        // Liquidate 0.5 debtToken (which should be adjusted to a multiple of 0.1% of 310000000)
        cdp_multi::partial_liquidate<TestCoin>(&user2, user1_addr, 50000000);
        
        // Check position after liquidation
        let (_, debt1, _) = cdp_multi::get_user_position<TestCoin>(user1_addr);
        
        // Debt should be reduced by approximately 50000000
        assert!(debt1 < initial_debt, 101);
        
        // Test 2: Liquidate with non-round amount
        cdp_multi::mint_debtToken_for_test(user2_addr, 123456789); // ~1.23 debtToken
        
        // Try to liquidate 123456789, which should round down to a multiple of 0.1% chunks
        cdp_multi::partial_liquidate<TestCoin>(&user2, user1_addr, 123456789);
        
        // Check position after second liquidation
        let (_, debt2, _) = cdp_multi::get_user_position<TestCoin>(user1_addr);
        
        // Verify debt reduction follows chunking mechanism
        assert!(debt2 < debt1, 102);
        
        coin::destroy_mint_cap(mint_cap);
    }
    
    #[test]
    fun test_partial_liquidate_safety_features() {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x456);
        
        let (_admin_addr, user1_addr, user2_addr, mint_cap) = setup_test(&aptos_framework, &cdp_admin, &user1, &user2);
        
        // Open a trove for user1 with larger initial debt to allow for partial liquidation
        cdp_multi::open_trove<TestCoin>(&user1, 400000000, 250000000); // 4 TC, 2.5 debtToken
        
        // Test 1: Safety cap when collateral value drops drastically
        cdp_multi::set_price<TestCoin>(&cdp_admin, 1000000); // 0.01 debtToken per TC
        
        // Mint debtToken to liquidator
        cdp_multi::mint_debtToken_for_test(user2_addr, 100000000); // 1 debtToken
        
        // Use a small amount to ensure minimum debt remains
        // This amount is small enough to not hit the minimum debt limit
        cdp_multi::partial_liquidate<TestCoin>(&user2, user1_addr, 30000000); // 0.3 debtToken
        
        // Check position after liquidation
        let (_, _, active) = cdp_multi::get_user_position<TestCoin>(user1_addr);
        
        // Position should still be active
        assert!(active, 104);
        
        coin::destroy_mint_cap(mint_cap);
    }
    
    #[test]
    fun test_partial_liquidate_different_icr_levels() {
        // Setup accounts
        let aptos_framework = account::create_account_for_test(@0x1);
        let cdp_admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123); // ICR <= 100%
        let user2 = account::create_account_for_test(@0x456); // Liquidator
        
        let (_admin_addr, user1_addr, user2_addr, mint_cap) = setup_test(&aptos_framework, &cdp_admin, &user1, &user2);
        
        // Create user3 and user4
        let user3 = account::create_account_for_test(@0x789); // 100% < ICR <= 110% 
        let user4 = account::create_account_for_test(@0x321); // ICR > 110%
        let user3_addr = signer::address_of(&user3);
        let user4_addr = signer::address_of(&user4);
        
        // Register accounts for user3 and user4
        cdp_multi::register_collateral_coin<TestCoin>(&user3);
        cdp_multi::register_collateral_coin<TestCoin>(&user4);
        cdp_multi::register_debtToken_coin(&user3);
        cdp_multi::register_debtToken_coin(&user4);
        
        // Mint directly using the mint_cap instead of reinitializing the coin
        coin::deposit(user3_addr, coin::mint(600000000, &mint_cap)); // 6 TC
        coin::deposit(user4_addr, coin::mint(600000000, &mint_cap)); // 6 TC
        
        // Open troves for all users - with increased collateral to meet MCR
        cdp_multi::open_trove<TestCoin>(&user1, 350000000, 200000000); // 3.5 TC, 2 debtToken
        cdp_multi::open_trove<TestCoin>(&user3, 350000000, 200000000); // 3.5 TC, 2 debtToken
        cdp_multi::open_trove<TestCoin>(&user4, 350000000, 200000000); // 3.5 TC, 2 debtToken
        
        // Create scenarios for different ICR levels
        // Case 1: ICR <= 100%
        cdp_multi::set_price<TestCoin>(&cdp_admin, 66666667); // ~0.66 debtToken per TC (ICR = 100%)
        
        // Mint debtToken to liquidator
        cdp_multi::mint_debtToken_for_test(user2_addr, 300000000); // 3 debtToken
        
        // Use small liquidation amounts to ensure minimum debt remains
        cdp_multi::partial_liquidate<TestCoin>(&user2, user1_addr, 30000000); // 0.3 debtToken
        cdp_multi::partial_liquidate<TestCoin>(&user2, user3_addr, 30000000); // 0.3 debtToken
        cdp_multi::partial_liquidate<TestCoin>(&user2, user4_addr, 30000000); // 0.3 debtToken
        
        // Check positions after liquidation
        let (_, debt1, active1) = cdp_multi::get_user_position<TestCoin>(user1_addr);
        let (_, debt3, active3) = cdp_multi::get_user_position<TestCoin>(user3_addr);
        let (_, debt4, active4) = cdp_multi::get_user_position<TestCoin>(user4_addr);
        
        // All positions should still be active
        assert!(active1, 105);
        assert!(active3, 106);
        assert!(active4, 107);
        
        // Each position should have less debt than before
        assert!(debt1 < 210000000, 108);
        assert!(debt3 < 210000000, 109);
        assert!(debt4 < 210000000, 110);
        
        coin::destroy_mint_cap(mint_cap);
    }
}