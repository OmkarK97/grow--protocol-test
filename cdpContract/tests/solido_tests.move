#[test_only]
module cdp::cdp_multi_test {
    use std::fixed_point32;
    use std::signer;
    use std::string;
    use aptos_std::type_info;
    use supra_framework::math64;
    use supra_framework::timestamp;
    use supra_framework::account;
    use supra_framework::coin;
    use supra_framework::block;
    use cdp::cdp_multi::{Self, CASH};
    use cdp::config;
    use cdp::price_oracle;
    use supra_framework::debug;
    use cdp::events;
    
    // Mock coins with different decimal precisions
    struct Coin6Decimals {}   // 6 decimals (less than debtToken's 8)
    struct Coin8Decimals {}   // 8 decimals (same as debtToken's 8)
    struct Coin10Decimals {}  // 10 decimals (more than debtToken's 8)
    
    // Fee collector address for tests
    const FEE_COLLECTOR: address = @0xFEE;
    
    // Test mint capabilities - store them during setup
    struct MintCapabilities has key {
        cap6: coin::MintCapability<Coin6Decimals>,
        cap8: coin::MintCapability<Coin8Decimals>,
        cap10: coin::MintCapability<Coin10Decimals>
    }
    
    // Test setup function
    fun setup_test(aptos_framework: &signer, admin: &signer) {
        // Mock the timestamp for tests
        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        // Create necessary accounts
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(FEE_COLLECTOR);
        
        // Initialize CDP system
        cdp_multi::initialize(admin, FEE_COLLECTOR);
        
        // Initialize test coins and store mint capabilities
        let (burn_cap6, freeze_cap6, mint_cap6) = initialize_test_coin<Coin6Decimals>(admin, 6);
        let (burn_cap8, freeze_cap8, mint_cap8) = initialize_test_coin<Coin8Decimals>(admin, 8);
        let (burn_cap10, freeze_cap10, mint_cap10) = initialize_test_coin<Coin10Decimals>(admin, 10);
        
        // Destroy burn and freeze capabilities
        coin::destroy_burn_cap(burn_cap6);
        coin::destroy_freeze_cap(freeze_cap6);
        coin::destroy_burn_cap(burn_cap8);
        coin::destroy_freeze_cap(freeze_cap8);
        coin::destroy_burn_cap(burn_cap10);
        coin::destroy_freeze_cap(freeze_cap10);
        
        // Store mint capabilities for later use
        move_to(admin, MintCapabilities {
            cap6: mint_cap6,
            cap8: mint_cap8,
            cap10: mint_cap10
        });
        
        // Add collateral to the CDP system
        cdp_multi::add_collateral<Coin6Decimals>(
            admin,
            /* minimum_debt */ 100 * math64::pow(10, 8), // 100 debtToken
            /* mcr */ 12000, // 120%
            /* borrow_rate */ 200, // 2%
            /* liquidation_reserve */ 10 * math64::pow(10, 8), // 10 debtToken
            /* liquidation_threshold */ 11500, // 110%
            /* liquidation_penalty */ 1000, // 10%
            /* redemption_fee */ 100, // 1%
            /* decimals */ 6,
            /* liquidation_fee_protocol */ 5000, // 50%
            /* redemption_fee_gratuity */ 100, // 1%
            /* oracle_id */ 1,
            /* price_age */ 60
        );
        
        cdp_multi::add_collateral<Coin8Decimals>(
            admin,
            /* minimum_debt */ 100 * math64::pow(10, 8),
            /* mcr */ 15000, // 150%
            /* borrow_rate */ 200, 
            /* liquidation_reserve */ 10 * math64::pow(10, 8),
            /* liquidation_threshold */ 11500,
            /* liquidation_penalty */ 1000,
            /* redemption_fee */ 100,
            /* decimals */ 8,
            /* liquidation_fee_protocol */ 5000,
            /* redemption_fee_gratuity */ 100,
            /* oracle_id */ 1,
            /* price_age */ 60
        );
        
        cdp_multi::add_collateral<Coin10Decimals>(
            admin,
            /* minimum_debt */ 100 * math64::pow(10, 8),
            /* mcr */ 18000, // 180%
            /* borrow_rate */ 200,
            /* liquidation_reserve */ 10 * math64::pow(10, 8),
            /* liquidation_threshold */ 11500,
            /* liquidation_penalty */ 1000,
            /* redemption_fee */ 100,
            /* decimals */ 10,
            /* liquidation_fee_protocol */ 5000,
            /* redemption_fee_gratuity */ 100,
            /* oracle_id */ 1,
            /* price_age */ 60
        );
        
        // Set prices for testing
        cdp_multi::set_price<Coin6Decimals>(admin, 100000000); // $1.00
        cdp_multi::set_price<Coin8Decimals>(admin, 200000000); // $2.00
        cdp_multi::set_price<Coin10Decimals>(admin, 50000000); // $0.50
    }
    
    // Helper to initialize a test coin
    fun initialize_test_coin<CoinType>(
        admin: &signer, 
        decimals: u8
    ): (coin::BurnCapability<CoinType>, coin::FreezeCapability<CoinType>, coin::MintCapability<CoinType>) {
        coin::initialize<CoinType>(
            admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            decimals,
            true
        )
    }

    // Helper to mint test coins using the stored capabilities
    fun mint_test_coins<CoinType>(admin_addr: address, user: &signer, amount: u64) acquires MintCapabilities {
        let user_addr = signer::address_of(user);
        
        if (std::type_info::type_of<CoinType>() == std::type_info::type_of<Coin6Decimals>()) {
            let cap = &borrow_global<MintCapabilities>(admin_addr).cap6;
            let coins = coin::mint(amount, cap);
            coin::deposit(user_addr, coins);
        } else if (std::type_info::type_of<CoinType>() == std::type_info::type_of<Coin8Decimals>()) {
            let cap = &borrow_global<MintCapabilities>(admin_addr).cap8;
            let coins = coin::mint(amount, cap);
            coin::deposit(user_addr, coins);
        } else if (std::type_info::type_of<CoinType>() == std::type_info::type_of<Coin10Decimals>()) {
            let cap = &borrow_global<MintCapabilities>(admin_addr).cap10;
            let coins = coin::mint(amount, cap);
            coin::deposit(user_addr, coins);
        }
    }

    #[test]
    fun test_verify_ratio_same_decimals() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Both have 8 decimals
        // - Collateral: 1000 tokens at $2.00 = $2000
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 200% (above MCR of 150%)
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            1000 * math64::pow(10, 8), // 1000 tokens with 8 decimals
            1000 * math64::pow(10, 8)  // 1000 debtToken with 8 decimals
        );
        
        // CASE: At exactly MCR (150%)
        // - Collateral: 750 tokens at $2.00 = $1500
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 150% (equal to MCR)
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            750 * math64::pow(10, 8), 
            1000 * math64::pow(10, 8)
        );
    }
    
    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)] // Use the actual err_insufficient_collateral code (3)
    fun test_verify_ratio_same_decimals_fails() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Below MCR (150%)
        // - Collateral: 700 tokens at $2.00 = $1400
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 140% (below MCR of 150%)
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            700 * math64::pow(10, 8),
            1000 * math64::pow(10, 8)
        );
    }
    
    #[test]
    fun test_verify_ratio_lower_decimals() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Collateral has 6 decimals (less than debt's 8)
        // - Collateral: 1200 tokens at $1.00 = $1200
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 120% (equal to MCR)
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            1200 * math64::pow(10, 6), // 1200 tokens with 6 decimals
            1000 * math64::pow(10, 8)  // 1000 debtToken with 8 decimals
        );
        
        // CASE: Well above MCR
        // - Collateral: 2400 tokens at $1.00 = $2400
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 240% (above MCR of 120%)
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            2400 * math64::pow(10, 6),
            1000 * math64::pow(10, 8)
        );
    }
    
    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)] // Use the actual err_insufficient_collateral code (3)
    fun test_verify_ratio_lower_decimals_fails() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Below MCR with lower decimals
        // - Collateral: 1100 tokens at $1.00 = $1100
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 110% (below MCR of 120%)
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            1100 * math64::pow(10, 6),
            1000 * math64::pow(10, 8)
        );
    }
    
    #[test]
    fun test_verify_ratio_higher_decimals() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Collateral has 10 decimals (more than debt's 8)
        // - Collateral: 3600 tokens at $0.50 = $1800
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 180% (equal to MCR)
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            3600 * math64::pow(10, 10), // 3600 tokens with 10 decimals
            1000 * math64::pow(10, 8)   // 1000 debtToken with 8 decimals
        );
        
        // CASE: Well above MCR
        // - Collateral: 7200 tokens at $0.50 = $3600
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 360% (above MCR of 180%)
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            7200 * math64::pow(10, 10),
            1000 * math64::pow(10, 8)
        );
    }
    
    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)] // Use the actual err_insufficient_collateral code (3)
    fun test_verify_ratio_higher_decimals_fails() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Below MCR with higher decimals
        // - Collateral: 3400 tokens at $0.50 = $1700
        // - Debt: 1000 debtToken at $1.00 = $1000
        // - Ratio: 170% (below MCR of 180%)
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            3400 * math64::pow(10, 10),
            1000 * math64::pow(10, 8)
        );
    }
    
    #[test]
    fun test_zero_debt() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Zero debt (should pass without checking ratio)
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            100 * math64::pow(10, 8), // Some non-zero collateral
            0                         // Zero debt
        );
    }
    
    #[test]
    fun test_edge_cases() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Very small values - at MCR (150%)
        // - Collateral: 0.000015 tokens at $2.00 = $0.00003
        // - Debt: 0.00002 debtToken at $1.00 = $0.00002
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            15 * math64::pow(10, 2), // 0.000015 tokens
            2 * math64::pow(10, 3)   // 0.00002 debtToken
        );
        
        // CASE: Very large values - at MCR (150%)
        // - Collateral: 1,500,000 tokens at $2.00 = $3,000,000
        // - Debt: 2,000,000 debtToken at $1.00 = $2,000,000
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            1500000 * math64::pow(10, 8), // 1,500,000 tokens
            2000000 * math64::pow(10, 8)  // 2,000,000 debtToken
        );
    }
    
    #[test]
    fun test_multiple_collateral_types() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // Test all collateral types in one test
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            1200 * math64::pow(10, 6), // 120% ratio (at MCR)
            1000 * math64::pow(10, 8)
        );
        
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            750 * math64::pow(10, 8), // 150% ratio (at MCR)
            1000 * math64::pow(10, 8)
        );
        
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            3600 * math64::pow(10, 10), // 180% ratio (at MCR)
            1000 * math64::pow(10, 8)
        );
    }

    #[test]
    fun test_large_numbers_with_different_decimals() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE 1: Large numbers with 6 decimals (lower than debtToken's 8)
        // - Collateral: 10,000,000 tokens at $1.00 = $10,000,000
        // - Debt: 8,000,000 debtToken at $1.00 = $8,000,000
        // - Ratio: 125% (above MCR of 120%)
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            10000000 * math64::pow(10, 6), // 10M tokens with 6 decimals
            8000000 * math64::pow(10, 8)   // 8M debtToken with 8 decimals
        );
        
        // CASE 2: Large numbers with 8 decimals (same as debtToken's 8)
        // - Collateral: 15,000,000 tokens at $2.00 = $30,000,000
        // - Debt: 18,000,000 debtToken at $1.00 = $18,000,000
        // - Ratio: 166.7% (above MCR of 150%)
        cdp_multi::verify_collateral_ratio<Coin8Decimals>(
            15000000 * math64::pow(10, 8),  // 15M tokens with 8 decimals
            18000000 * math64::pow(10, 8)   // 18M debtToken with 8 decimals
        );
        
        // CASE 3: Large numbers with 10 decimals (higher than debtToken's 8)
        // - Collateral: 100,000,000 tokens at $0.50 = $50,000,000
        // - Debt: 25,000,000 debtToken at $1.00 = $25,000,000
        // - Ratio: 200% (above MCR of 180%)
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            100000000 * math64::pow(10, 10), // 100M tokens with 10 decimals
            25000000 * math64::pow(10, 8)    // 25M debtToken with 8 decimals
        );
        
        // CASE 4: Extreme values (testing for potential overflow)
        // Using u64 safe limits but still very large numbers
        // - Collateral: ~1 billion tokens at $0.50 = $500,000,000
        // - Debt: 250,000,000 debtToken at $1.00 = $250,000,000
        // - Ratio: 200% (above MCR of 180%)
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            1000000000 * math64::pow(10, 10), // ~1B tokens with 10 decimals
            250000000 * math64::pow(10, 8)    // 250M debtToken with 8 decimals
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)]
    fun test_large_numbers_below_mcr() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // CASE: Large numbers with ratio below MCR
        // - Collateral: 9,000,000 tokens at $1.00 = $9,000,000
        // - Debt: 8,000,000 debtToken at $1.00 = $8,000,000
        // - Ratio: 112.5% (below MCR of 120%)
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            9000000 * math64::pow(10, 6), // 9M tokens with 6 decimals
            8000000 * math64::pow(10, 8)  // 8M debtToken with 8 decimals
        );
    }

    #[test]
    fun test_potential_overflow_points() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // Test Case 1: Near u64 limits with different decimal precision
        // Calculate values close to u64.max_value / price to test multiply_u64 safety
        // u64.max ~= 18.4 * 10^18, so with price of 0.5, we want collateral ~= 3.6 * 10^18
        // For 10 decimals, that's 3.6 * 10^8 tokens (without decimal part)
        let near_max_collateral = 360000000 * math64::pow(10, 10); // 360M tokens with 10 decimals
        let large_debt = 100000000 * math64::pow(10, 8);          // 100M debtToken with 8 decimals
        // Ratio: ~180% (at MCR exactly)
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            near_max_collateral,
            large_debt
        );
        
        // Test Case 2: Edge case with decimal adjustment
        // For 6 decimals to 8 decimals adjustment (multiply by 100)
        // Choose values such that collateral_value * 100 is close to u64.max
        // With price of 1.0, we want collateral ~= 1.8 * 10^16 / 100 = 1.8 * 10^14
        // For 6 decimals, that's 1.8 * 10^8 = 180M tokens
        let near_decimal_adjustment_limit = 180000000 * math64::pow(10, 6); // 180M tokens
        let medium_debt = 150000000 * math64::pow(10, 8);                  // 150M debtToken
        // Ratio: 120% (at MCR exactly)
        cdp_multi::verify_collateral_ratio<Coin6Decimals>(
            near_decimal_adjustment_limit,
            medium_debt
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)] // Expect insufficient collateral error instead of overflow
    fun test_definite_overflow() {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        setup_test(&aptos_framework, &admin);
        
        // Use truly extreme values - these will now be handled by u128 but will fail the collateral check
        // Maximum possible u64 value for collateral
        let max_collateral = 18446744073709551615; // u64::MAX
        let large_debt = 10000000000 * math64::pow(10, 8); // 10 billion debtToken
        
        // This will now fail with insufficient collateral rather than overflow
        cdp_multi::verify_collateral_ratio<Coin10Decimals>(
            max_collateral,
            large_debt
        );
    }

    #[test]
    fun test_open_trove_with_different_decimals() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register user for the collateral coins and debtToken
        coin::register<Coin6Decimals>(&user);
        coin::register<Coin8Decimals>(&user);
        coin::register<Coin10Decimals>(&user);
        coin::register<CASH>(&user);
        
        // Create the fee collector signer and register for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin6Decimals>(@cdp, &user, 10000 * math64::pow(10, 6));
        mint_test_coins<Coin8Decimals>(@cdp, &user, 5000 * math64::pow(10, 8));
        mint_test_coins<Coin10Decimals>(@cdp, &user, 20000 * math64::pow(10, 10));
        
        // Test opening troves with different collateral types
        
        // 1. Coin6Decimals (6 decimals, lower than debtToken's 8)
        cdp_multi::open_trove<Coin6Decimals>(
            &user,
            2000 * math64::pow(10, 6),
            1000 * math64::pow(10, 8)
        );       
        
        // 2. Coin8Decimals (8 decimals, same as debtToken's 8)
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1500 * math64::pow(10, 8),
            1500 * math64::pow(10, 8)
        );
        
        // 3. Coin10Decimals (10 decimals, higher than debtToken's 8)
        cdp_multi::open_trove<Coin10Decimals>(
            &user,
            10000 * math64::pow(10, 10),
            2000 * math64::pow(10, 8)
        );
        
        // Verify troves were created correctly
        let (collateral1, debt1, active1) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (collateral2, debt2, active2) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let (collateral3, debt3, active3) = cdp_multi::get_user_position<Coin10Decimals>(@0x123);
        
        // Check that all troves are active
        assert!(active1, 0);
        assert!(active2, 0);
        assert!(active3, 0);
        
        // Check that collateral amounts are correct
        assert!(collateral1 == 2000 * math64::pow(10, 6), 0);
        assert!(collateral2 == 1500 * math64::pow(10, 8), 0);
        assert!(collateral3 == 10000 * math64::pow(10, 10), 0);
        
        // Check that debt amounts include borrow fees and liquidation reserve
        assert!(debt1 > 1000 * math64::pow(10, 8), 0);
        assert!(debt2 > 1500 * math64::pow(10, 8), 0);
        assert!(debt3 > 2000 * math64::pow(10, 8), 0);
        
        // Check that user received the correct amount of debtToken
        let user_debtToken_balance = coin::balance<CASH>(@0x123);
        let expected_balance = 4500 * math64::pow(10, 8); // 1000 + 1500 + 2000 debtToken
        assert!(user_debtToken_balance == expected_balance, 0);
        
        // Check that total stats were updated
        let (total_collateral1, total_debt1) = cdp_multi::get_total_stats<Coin6Decimals>();
        let (total_collateral2, total_debt2) = cdp_multi::get_total_stats<Coin8Decimals>();
        let (total_collateral3, total_debt3) = cdp_multi::get_total_stats<Coin10Decimals>();
        
        assert!(total_collateral1 == collateral1, 0);
        assert!(total_debt1 == debt1, 0);
        assert!(total_collateral2 == collateral2, 0);
        assert!(total_debt2 == debt2, 0);
        assert!(total_collateral3 == collateral3, 0);
        assert!(total_debt3 == debt3, 0);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)]
    fun test_open_trove_insufficient_collateral_alternative() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register user for the collateral coin
        coin::register<Coin8Decimals>(&user);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 5000 * math64::pow(10, 8));
        
        // Try to open a trove with insufficient collateral
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            700 * math64::pow(10, 8),  // 700 tokens with 8 decimals
            1000 * math64::pow(10, 8)  // 1,000 debtToken with 8 decimals
        );
    }

    #[test]
    fun test_open_trove_large_numbers() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register user for the collateral coins and debtToken
        coin::register<Coin6Decimals>(&user);
        coin::register<Coin8Decimals>(&user);
        coin::register<Coin10Decimals>(&user);
        coin::register<CASH>(&user);
        
        // Create the fee collector signer and register for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint large amounts of collateral to user
        mint_test_coins<Coin6Decimals>(@cdp, &user, 50000000 * math64::pow(10, 6)); // 50M tokens
        mint_test_coins<Coin8Decimals>(@cdp, &user, 25000000 * math64::pow(10, 8)); // 25M tokens
        mint_test_coins<Coin10Decimals>(@cdp, &user, 100000000 * math64::pow(10, 10)); // 100M tokens
        
        // Open troves with large amounts of collateral and debt, accounting for fees
        
        // 1. Large numbers with 6 decimals (lower than debtToken's 8)
        // - Debt: 8,000,000 debtToken + ~3% fees  8,240,000 debtToken
        // - Required value: 8,240,000 * 1.2 = 9,888,000
        // - Required collateral: 9,888,000 / $1.00 = 9,888,000 tokens
        cdp_multi::open_trove<Coin6Decimals>(
            &user,
            10500000 * math64::pow(10, 6), // 10.5M tokens with 6 decimals
            8000000 * math64::pow(10, 8)   // 8M debtToken
        );
        
        // 2. Large numbers with 8 decimals (same as debtToken's 8)
        // - Debt: 13,000,000 debtToken + ~3% fees  13,390,000 debtToken
        // - Required value: 13,390,000 * 1.5 = 20,085,000
        // - Required collateral: 20,085,000 / $2.00 = 10,042,500 tokens
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            10100000 * math64::pow(10, 8),  // 10.1M tokens with 8 decimals
            13000000 * math64::pow(10, 8)   // 13M debtToken
        );
        
        // 3. Large numbers with 10 decimals (higher than debtToken's 8)
        // - Debt: 22,000,000 debtToken + ~3% fees  22,660,000 debtToken
        // - Required value: 22,660,000 * 1.8 = 40,788,000
        // - Required collateral: 40,788,000 / $0.50 = 81,576,000 tokens
        cdp_multi::open_trove<Coin10Decimals>(
            &user,
            82000000 * math64::pow(10, 10), // 82M tokens with 10 decimals
            22000000 * math64::pow(10, 8)   // 22M debtToken
        );
        
        // Verify troves were created correctly
        let (collateral1, debt1, active1) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (collateral2, debt2, active2) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let (collateral3, debt3, active3) = cdp_multi::get_user_position<Coin10Decimals>(@0x123);
        
        // Check that all troves are active with correct collateral
        assert!(active1, 0);
        assert!(active2, 0);
        assert!(active3, 0);
        assert!(collateral1 == 10500000 * math64::pow(10, 6), 0);
        assert!(collateral2 == 10100000 * math64::pow(10, 8), 0);
        assert!(collateral3 == 82000000 * math64::pow(10, 10), 0);
        
        // Check that debt amounts are greater than requested due to fees
        assert!(debt1 > 8000000 * math64::pow(10, 8), 0);
        assert!(debt2 > 13000000 * math64::pow(10, 8), 0);
        assert!(debt3 > 22000000 * math64::pow(10, 8), 0);
        
        // Check total debtToken minted (excluding fees and reserves)
        let user_debtToken_balance = coin::balance<CASH>(@0x123);
        let expected_balance = 43000000 * math64::pow(10, 8); // 8M + 13M + 22M debtToken
        assert!(user_debtToken_balance == expected_balance, 0);
    }

    #[test]
    fun test_open_trove_edge_cases() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x456); // Create a second user
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register users for coins
        coin::register<Coin8Decimals>(&user1);
        coin::register<CASH>(&user1);
        coin::register<Coin8Decimals>(&user2);
        coin::register<CASH>(&user2);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to both users
        mint_test_coins<Coin8Decimals>(@cdp, &user1, 200 * math64::pow(10, 8)); // For user1 test
        mint_test_coins<Coin8Decimals>(@cdp, &user2, 1000000 * math64::pow(10, 8)); // For user2 test
        
        // CASE 1: Minimum debt allowed with sufficient collateral (using user1)
        // Minimum debt is 100 debtToken as specified in add_collateral
        // With MCR of 150% and 3.1% for fees, we need about 78 tokens
        cdp_multi::open_trove<Coin8Decimals>(
            &user1,
            85 * math64::pow(10, 8), // 85 tokens at $2.00 = $170 (with safety margin)
            100 * math64::pow(10, 8)  // 100 debtToken (minimum debt)
        );
        
        // CASE 2: Slightly above MCR accounting for fees with medium debt (using user2)
        // - Debt: 2,000 debtToken + ~3.1% fees = 2,062 debtToken
        // - Required value: 2,062 * 1.5 = 3,093
        // - Required collateral: 3,093 / $2.00 = 1,546.5 tokens
        cdp_multi::open_trove<Coin8Decimals>(
            &user2,
            1560 * math64::pow(10, 8), // 1,560 tokens at $2.00 = $3,120 (with safety margin)
            2000 * math64::pow(10, 8)  // 2,000 debtToken
        );
        
        // Verify troves were created correctly
        let (collateral1, debt1, active1) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let (collateral2, debt2, active2) = cdp_multi::get_user_position<Coin8Decimals>(@0x456);
        
        // Check both troves
        assert!(active1, 0);
        assert!(active2, 0);
        assert!(collateral1 == 85 * math64::pow(10, 8), 0);
        assert!(collateral2 == 1560 * math64::pow(10, 8), 0);
        assert!(debt1 > 100 * math64::pow(10, 8), 0); // Includes fees and reserve
        assert!(debt2 > 2000 * math64::pow(10, 8), 0); // Includes fees and reserve
        
        // Check users received debtToken
        let user1_debtToken_balance = coin::balance<CASH>(@0x123);
        let user2_debtToken_balance = coin::balance<CASH>(@0x456);
        assert!(user1_debtToken_balance == 100 * math64::pow(10, 8), 0); // 100 debtToken
        assert!(user2_debtToken_balance == 2000 * math64::pow(10, 8), 0); // 2000 debtToken
    }

    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)]
    fun test_open_trove_exact_mcr_minus_one() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register user for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 1000 * math64::pow(10, 8));
        
        // Try to open trove with collateral ratio just slightly below MCR
        // For Coin8Decimals, MCR is 150%
        // - Collateral: 749 tokens at $2.00 = $1,498
        // - Debt: 1,000 debtToken
        // - Ratio: 149.8% (just below MCR of 150%)
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            749 * math64::pow(10, 8), // 749 tokens
            1000 * math64::pow(10, 8) // 1,000 debtToken
        );
    }

    #[test]
    fun test_open_trove_exact_mcr_plus_one() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register user for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 1000 * math64::pow(10, 8));
        
        // Open trove with collateral ratio accounting for fees
        // For 1,000 debtToken debt + ~3% fees (~1,030 debtToken)
        // At MCR of 150%, we need $1,545 value
        // At $2.00 per token, we need 772.5 tokens
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            775 * math64::pow(10, 8), // 775 tokens
            1000 * math64::pow(10, 8) // 1,000 debtToken
        );
        
        // Verify trove was created correctly
        let (collateral, debt, active) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        assert!(active, 0);
        assert!(collateral == 775 * math64::pow(10, 8), 0);
        assert!(debt > 1000 * math64::pow(10, 8), 0); // Includes fees and reserve
        
        // Check user received debtToken
        let user_debtToken_balance = coin::balance<CASH>(@0x123);
        assert!(user_debtToken_balance == 1000 * math64::pow(10, 8), 0);
    }

    #[test]
    fun test_deposit_or_mint_operations() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register user for the collateral coins and debtToken
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 5000 * math64::pow(10, 8)); // 5000 tokens
        
        // First, open a trove with initial collateral and debt
        // Initial position: 1000 tokens with 500 debtToken debt
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens
            500 * math64::pow(10, 8)   // 500 debtToken
        );
        
        // Get initial position
        let (initial_collateral, initial_debt, initial_active) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let initial_debtToken_balance = coin::balance<CASH>(@0x123);
        
        // 1. Test deposit only (no minting)
        cdp_multi::deposit_or_mint<Coin8Decimals>(
            &user,
            500 * math64::pow(10, 8), // 500 more tokens
            0                         // 0 debtToken (no minting)
        );
        
        // Verify position after deposit only
        let (collateral_after_deposit, debt_after_deposit, active_after_deposit) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(collateral_after_deposit == initial_collateral + 500 * math64::pow(10, 8), 0); // +500 tokens
        assert!(debt_after_deposit == initial_debt, 0); // Debt unchanged
        assert!(active_after_deposit == initial_active, 0); // Still active
        assert!(coin::balance<CASH>(@0x123) == initial_debtToken_balance, 0); // debtToken balance unchanged
        
        // 2. Test mint only (no deposit)
        let pre_mint_collateral = collateral_after_deposit;
        let pre_mint_debt = debt_after_deposit;
        let pre_mint_debtToken = coin::balance<CASH>(@0x123);
        
        cdp_multi::deposit_or_mint<Coin8Decimals>(
            &user,
            0,                         // 0 tokens (no deposit)
            300 * math64::pow(10, 8)   // 300 more debtToken
        );
        
        // Verify position after mint only
        let (collateral_after_mint, debt_after_mint, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(collateral_after_mint == pre_mint_collateral, 0); // Collateral unchanged
        assert!(debt_after_mint > pre_mint_debt, 0); // Debt increased by more than 300 debtToken (includes fee)
        assert!(debt_after_mint == pre_mint_debt + 300 * math64::pow(10, 8) + (300 * math64::pow(10, 8) * 200) / 10000, 0); // Debt + requested + fee
        assert!(coin::balance<CASH>(@0x123) == pre_mint_debtToken + 300 * math64::pow(10, 8), 0); // debtToken balance increased by 300
        
        // 3. Test both deposit and mint in one transaction
        let pre_both_collateral = collateral_after_mint;
        let pre_both_debt = debt_after_mint;
        let pre_both_debtToken = coin::balance<CASH>(@0x123);
        
        cdp_multi::deposit_or_mint<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8),  // 1000 more tokens
            200 * math64::pow(10, 8)    // 200 more debtToken
        );
        
        // Verify position after both operations
        let (collateral_after_both, debt_after_both, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(collateral_after_both == pre_both_collateral + 1000 * math64::pow(10, 8), 0); // +1000 tokens
        assert!(debt_after_both > pre_both_debt, 0); // Debt increased
        assert!(debt_after_both == pre_both_debt + 200 * math64::pow(10, 8) + (200 * math64::pow(10, 8) * 200) / 10000, 0); // Debt + requested + fee
        assert!(coin::balance<CASH>(@0x123) == pre_both_debtToken + 200 * math64::pow(10, 8), 0); // debtToken balance increased by 200
        
        // Check total stats were updated correctly
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<Coin8Decimals>();
        assert!(total_collateral == collateral_after_both, 0);
        assert!(total_debt == debt_after_both, 0);
    }

    #[test]
    fun test_deposit_or_mint_different_decimals() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x456);
        
        // Initialize block module for testing
        block::initialize_for_test(&aptos_framework, 1);
        
        // Setup test environment
        setup_test(&aptos_framework, &admin);
        
        // Register users for the collateral coins and debtToken
        coin::register<Coin6Decimals>(&user1);
        coin::register<Coin10Decimals>(&user2);
        coin::register<CASH>(&user1);
        coin::register<CASH>(&user2);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint collateral to users
        mint_test_coins<Coin6Decimals>(@cdp, &user1, 10000 * math64::pow(10, 6)); // 10,000 tokens with 6 decimals
        mint_test_coins<Coin10Decimals>(@cdp, &user2, 30000 * math64::pow(10, 10)); // 30,000 tokens with 10 decimals
        
        // 1. Test with Coin6Decimals (lower precision than debtToken)
        cdp_multi::open_trove<Coin6Decimals>(
            &user1,
            5000 * math64::pow(10, 6),  // 5000 tokens with 6 decimals at $1.00 = $5,000
            2000 * math64::pow(10, 8)   // 2000 debtToken
        );
        
        let (initial_collateral6, initial_debt6, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let initial_debtToken_balance1 = coin::balance<CASH>(@0x123);
        
        // Deposit more collateral and mint more debtToken
        cdp_multi::deposit_or_mint<Coin6Decimals>(
            &user1,
            1000 * math64::pow(10, 6),  // 1000 more tokens with 6 decimals
            500 * math64::pow(10, 8)    // 500 more debtToken
        );
        
        // Verify position update with lower precision
        let (collateral_after6, debt_after6, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        assert!(collateral_after6 == initial_collateral6 + 1000 * math64::pow(10, 6), 0); // Collateral increased
        assert!(debt_after6 > initial_debt6, 0); // Debt increased
        assert!(debt_after6 == initial_debt6 + 500 * math64::pow(10, 8) + (500 * math64::pow(10, 8) * 200) / 10000, 0); // Include fee
        assert!(coin::balance<CASH>(@0x123) == initial_debtToken_balance1 + 500 * math64::pow(10, 8), 0); // debtToken balance increased
        
        // 2. Test with Coin10Decimals (higher precision than debtToken)
        cdp_multi::open_trove<Coin10Decimals>(
            &user2,
            18000 * math64::pow(10, 10), // 18000 tokens with 10 decimals at $0.50 = $9,000
            3000 * math64::pow(10, 8)    // 3000 debtToken
        );
        
        let (initial_collateral10, initial_debt10, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x456);
        let initial_debtToken_balance2 = coin::balance<CASH>(@0x456);
        
        // Deposit more collateral and mint more debtToken
        cdp_multi::deposit_or_mint<Coin10Decimals>(
            &user2,
            4000 * math64::pow(10, 10),  // 4000 more tokens with 10 decimals
            1000 * math64::pow(10, 8)    // 1000 more debtToken
        );
        
        // Verify position update with higher precision
        let (collateral_after10, debt_after10, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x456);
        assert!(collateral_after10 == initial_collateral10 + 4000 * math64::pow(10, 10), 0); // Collateral increased
        assert!(debt_after10 > initial_debt10, 0); // Debt increased
        assert!(debt_after10 == initial_debt10 + 1000 * math64::pow(10, 8) + (1000 * math64::pow(10, 8) * 200) / 10000, 0); // Include fee
        assert!(coin::balance<CASH>(@0x456) == initial_debtToken_balance2 + 1000 * math64::pow(10, 8), 0); // debtToken balance increased
        
        // Check total stats for both collateral types
        let (total_collateral6, total_debt6) = cdp_multi::get_total_stats<Coin6Decimals>();
        let (total_collateral10, total_debt10) = cdp_multi::get_total_stats<Coin10Decimals>();
        assert!(total_collateral6 == collateral_after6, 0);
        assert!(total_debt6 == debt_after6, 0);
        assert!(total_collateral10 == collateral_after10, 0);
        assert!(total_debt10 == debt_after10, 0);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)] // err_insufficient_collateral
    fun test_deposit_or_mint_insufficient_collateral() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        mint_test_coins<Coin8Decimals>(@cdp, &user, 2000 * math64::pow(10, 8));
        
        // Open a trove with minimal collateral
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            800 * math64::pow(10, 8), // 800 tokens
            500 * math64::pow(10, 8)  // 500 debtToken
        );
        
        // Try to mint too much debtToken without adding more collateral
        // This should fail because it would put the position below MCR
        cdp_multi::deposit_or_mint<Coin8Decimals>(
            &user,
            0,                        // No additional collateral
            1000 * math64::pow(10, 8) // 1000 debtToken (too much for current collateral)
        );
    }

    #[test]
    fun test_repay_or_withdraw_operations() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        mint_test_coins<Coin8Decimals>(@cdp, &user, 5000 * math64::pow(10, 8));
        
        // Open a trove with substantial collateral and debt
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            3000 * math64::pow(10, 8), // 3000 tokens at $2.00 = $6,000
            1000 * math64::pow(10, 8)  // 1000 debtToken
        );
        
        // Get initial position and balances
        let (initial_collateral, initial_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let initial_debtToken_balance = coin::balance<CASH>(@0x123);
        let initial_token_balance = coin::balance<Coin8Decimals>(@0x123);
        
        // 1. Test repay only (no withdrawal)
        cdp_multi::repay_or_withdraw<Coin8Decimals>(
            &user,
            0,                         // 0 tokens (no withdrawal)
            200 * math64::pow(10, 8)   // 200 debtToken repayment
        );
        
        // Verify position after repay only
        let (collateral_after_repay, debt_after_repay, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(collateral_after_repay == initial_collateral, 0); // Collateral unchanged
        assert!(debt_after_repay == initial_debt - 200 * math64::pow(10, 8), 0); // Debt reduced by 200 debtToken
        assert!(coin::balance<CASH>(@0x123) == initial_debtToken_balance - 200 * math64::pow(10, 8), 0); // debtToken balance reduced
        assert!(coin::balance<Coin8Decimals>(@0x123) == initial_token_balance, 0); // Token balance unchanged
        
        // 2. Test withdraw only (no repayment)
        let pre_withdraw_collateral = collateral_after_repay;
        let pre_withdraw_debt = debt_after_repay;
        let pre_withdraw_token = coin::balance<Coin8Decimals>(@0x123);
        
        cdp_multi::repay_or_withdraw<Coin8Decimals>(
            &user,
            500 * math64::pow(10, 8),  // 500 tokens withdrawal
            0                          // 0 debtToken (no repayment)
        );
        
        // Verify position after withdraw only
        let (collateral_after_withdraw, debt_after_withdraw, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(collateral_after_withdraw == pre_withdraw_collateral - 500 * math64::pow(10, 8), 0); // Collateral reduced
        assert!(debt_after_withdraw == pre_withdraw_debt, 0); // Debt unchanged
        assert!(coin::balance<Coin8Decimals>(@0x123) == pre_withdraw_token + 500 * math64::pow(10, 8), 0); // Token balance increased
        
        // 3. Test both repay and withdraw in one transaction
        let pre_both_collateral = collateral_after_withdraw;
        let pre_both_debt = debt_after_withdraw;
        let pre_both_debtToken = coin::balance<CASH>(@0x123);
        let pre_both_token = coin::balance<Coin8Decimals>(@0x123);
        
        cdp_multi::repay_or_withdraw<Coin8Decimals>(
            &user,
            300 * math64::pow(10, 8),  // 300 tokens withdrawal
            300 * math64::pow(10, 8)   // 300 debtToken repayment
        );
        
        // Verify position after both operations
        let (collateral_after_both, debt_after_both, active_after_both) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(collateral_after_both == pre_both_collateral - 300 * math64::pow(10, 8), 0); // Collateral reduced
        assert!(debt_after_both == pre_both_debt - 300 * math64::pow(10, 8), 0); // Debt reduced
        assert!(active_after_both, 0); // Position still active
        assert!(coin::balance<CASH>(@0x123) == pre_both_debtToken - 300 * math64::pow(10, 8), 0); // debtToken balance reduced
        assert!(coin::balance<Coin8Decimals>(@0x123) == pre_both_token + 300 * math64::pow(10, 8), 0); // Token balance increased
        
        // Check total stats were updated correctly
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<Coin8Decimals>();
        assert!(total_collateral == collateral_after_both, 0);
        assert!(total_debt == debt_after_both, 0);
    }

    #[test]
    fun test_repay_or_withdraw_different_decimals() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register users for different coins
        coin::register<Coin6Decimals>(&user1);
        coin::register<Coin10Decimals>(&user2);
        coin::register<CASH>(&user1);
        coin::register<CASH>(&user2);
        
        // Register fee collector
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint collateral to users
        mint_test_coins<Coin6Decimals>(@cdp, &user1, 10000 * math64::pow(10, 6)); // 10,000 tokens with 6 decimals
        mint_test_coins<Coin10Decimals>(@cdp, &user2, 30000 * math64::pow(10, 10)); // 30,000 tokens with 10 decimals
        
        // 1. Test with Coin6Decimals (lower precision than debtToken)
        cdp_multi::open_trove<Coin6Decimals>(
            &user1,
            6000 * math64::pow(10, 6),  // 6000 tokens with 6 decimals at $1.00 = $6,000
            2000 * math64::pow(10, 8)   // 2000 debtToken
        );
        
        let (initial_collateral6, initial_debt6, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let initial_debtToken_balance1 = coin::balance<CASH>(@0x123);
        let initial_token_balance1 = coin::balance<Coin6Decimals>(@0x123);
        
        // Perform repay and withdraw
        cdp_multi::repay_or_withdraw<Coin6Decimals>(
            &user1,
            1000 * math64::pow(10, 6),  // 1000 tokens withdrawal
            500 * math64::pow(10, 8)    // 500 debtToken repayment
        );
        
        // Verify position with lower precision
        let (collateral_after6, debt_after6, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        assert!(collateral_after6 == initial_collateral6 - 1000 * math64::pow(10, 6), 0); // Collateral decreased
        assert!(debt_after6 == initial_debt6 - 500 * math64::pow(10, 8), 0); // Debt decreased
        assert!(coin::balance<CASH>(@0x123) == initial_debtToken_balance1 - 500 * math64::pow(10, 8), 0);
        assert!(coin::balance<Coin6Decimals>(@0x123) == initial_token_balance1 + 1000 * math64::pow(10, 6), 0);
        
        // 2. Test with Coin10Decimals (higher precision than debtToken)
        cdp_multi::open_trove<Coin10Decimals>(
            &user2,
            18000 * math64::pow(10, 10), // 18000 tokens with 10 decimals at $0.50 = $9,000
            3000 * math64::pow(10, 8)    // 3000 debtToken
        );
        
        let (initial_collateral10, initial_debt10, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x456);
        let initial_debtToken_balance2 = coin::balance<CASH>(@0x456);
        let initial_token_balance2 = coin::balance<Coin10Decimals>(@0x456);
        
        // Perform repay and withdraw
        cdp_multi::repay_or_withdraw<Coin10Decimals>(
            &user2,
            4000 * math64::pow(10, 10),  // 4000 tokens withdrawal
            1000 * math64::pow(10, 8)    // 1000 debtToken repayment
        );
        
        // Verify position with higher precision
        let (collateral_after10, debt_after10, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x456);
        assert!(collateral_after10 == initial_collateral10 - 4000 * math64::pow(10, 10), 0); // Collateral decreased
        assert!(debt_after10 == initial_debt10 - 1000 * math64::pow(10, 8), 0); // Debt decreased
        assert!(coin::balance<CASH>(@0x456) == initial_debtToken_balance2 - 1000 * math64::pow(10, 8), 0);
        assert!(coin::balance<Coin10Decimals>(@0x456) == initial_token_balance2 + 4000 * math64::pow(10, 10), 0);
        
        // Check total stats for both collateral types
        let (total_collateral6, total_debt6) = cdp_multi::get_total_stats<Coin6Decimals>();
        let (total_collateral10, total_debt10) = cdp_multi::get_total_stats<Coin10Decimals>();
        assert!(total_collateral6 == collateral_after6, 0);
        assert!(total_debt6 == debt_after6, 0);
        assert!(total_collateral10 == collateral_after10, 0);
        assert!(total_debt10 == debt_after10, 0);
    }

 

    #[test]
    #[expected_failure(abort_code = 3, location = cdp_multi)] // err_insufficient_collateral
    fun test_withdraw_insufficient_collateral_remaining() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        mint_test_coins<Coin8Decimals>(@cdp, &user, 2000 * math64::pow(10, 8));
        
        // Open a trove with just enough collateral for the debt
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            800 * math64::pow(10, 8), // 800 tokens at $2.00 = $1,600
            1000 * math64::pow(10, 8) // 1000 debtToken (with ~3% fees, requires ~775 tokens at MCR)
        );
        
        // Try to withdraw too much collateral while maintaining same debt
        cdp_multi::repay_or_withdraw<Coin8Decimals>(
            &user,
            100 * math64::pow(10, 8), // 100 tokens withdrawal (would put position below MCR)
            0                         // No debt repayment
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = cdp_multi)] // Update to the actual error code
    fun test_repay_below_minimum_debt() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        mint_test_coins<Coin8Decimals>(@cdp, &user, 2000 * math64::pow(10, 8));
        
        // Open a trove with debt slightly above minimum
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens
            150 * math64::pow(10, 8)   // 150 debtToken (minimum is 100 + liquidation reserve)
        );
        
        // Get initial debt
        let (_, initial_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        // Mint extra debtToken for repayment
        cdp_multi::mint_debtToken_for_test(@0x123, initial_debt);
        
        // Try to repay too much, going below minimum debt but not to zero
        // This should fail because minimum debt is 100 debtToken + liquidation reserve
        cdp_multi::repay_or_withdraw<Coin8Decimals>(
            &user,
            0,
            initial_debt - 90 * math64::pow(10, 8) // Leave only 90 debtToken debt
        );
    }

    #[test]
    fun test_close_trove() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral and debtToken for testing
        mint_test_coins<Coin8Decimals>(@cdp, &user, 2000 * math64::pow(10, 8));
        
        // Open a trove
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens
            500 * math64::pow(10, 8)   // 500 debtToken
        );
        
        // Get initial position data and balances
        let (initial_collateral, initial_debt, active_before) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let initial_token_balance = coin::balance<Coin8Decimals>(@0x123);
        let user_addr = signer::address_of(&user);
        
        assert!(active_before, 0); // Position should be active
        
        // Mint enough debtToken to repay debt (including fees and liquidation reserve)
        cdp_multi::mint_debtToken_for_test(user_addr, initial_debt);
        
        // Close trove - this is the proper way to close a position
        cdp_multi::close_trove<Coin8Decimals>(&user);
        
        // Verify position is closed
        let (final_collateral, final_debt, active_after) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(final_collateral == 0, 0); // No collateral left
        assert!(final_debt == 0, 0); // No debt left
        assert!(!active_after, 0); // Position should be inactive now
        
        // Verify collateral was returned
        assert!(coin::balance<Coin8Decimals>(@0x123) == initial_token_balance + initial_collateral, 0);
        
        // Check total stats are updated correctly
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<Coin8Decimals>();
        assert!(total_collateral == 0, 0); // No collateral in the system
        assert!(total_debt == 0, 0); // No debt in the system
    }

    #[test]
    fun test_close_trove_different_decimals() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register users for different coins
        coin::register<Coin6Decimals>(&user1);
        coin::register<Coin10Decimals>(&user2);
        coin::register<CASH>(&user1);
        coin::register<CASH>(&user2);
        
        // Register fee collector
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint collateral to users
        mint_test_coins<Coin6Decimals>(@cdp, &user1, 10000 * math64::pow(10, 6)); // 10,000 tokens with 6 decimals
        mint_test_coins<Coin10Decimals>(@cdp, &user2, 30000 * math64::pow(10, 10)); // 30,000 tokens with 10 decimals
        
        // 1. Test with Coin6Decimals (lower precision than debtToken)
        cdp_multi::open_trove<Coin6Decimals>(
            &user1,
            6000 * math64::pow(10, 6),  // 6000 tokens with 6 decimals at $1.00 = $6,000
            2000 * math64::pow(10, 8)   // 2000 debtToken
        );
        
        // 2. Test with Coin10Decimals (higher precision than debtToken)
        cdp_multi::open_trove<Coin10Decimals>(
            &user2,
            18000 * math64::pow(10, 10), // 18000 tokens with 10 decimals at $0.50 = $9,000
            3000 * math64::pow(10, 8)    // 3000 debtToken
        );
        
        // Get initial positions and balances
        let (initial_collateral6, initial_debt6, active6_before) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (initial_collateral10, initial_debt10, active10_before) = cdp_multi::get_user_position<Coin10Decimals>(@0x456);
        let initial_token_balance1 = coin::balance<Coin6Decimals>(@0x123);
        let initial_token_balance2 = coin::balance<Coin10Decimals>(@0x456);
        
        // Verify initial positions are active
        assert!(active6_before, 0);
        assert!(active10_before, 0);
        
        // Mint enough debtToken to repay debt for both users
        cdp_multi::mint_debtToken_for_test(@0x123, initial_debt6);
        cdp_multi::mint_debtToken_for_test(@0x456, initial_debt10);
        
        // Close both troves
        cdp_multi::close_trove<Coin6Decimals>(&user1);
        cdp_multi::close_trove<Coin10Decimals>(&user2);
        
        // Verify positions are closed
        let (final_collateral6, final_debt6, active6_after) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (final_collateral10, final_debt10, active10_after) = cdp_multi::get_user_position<Coin10Decimals>(@0x456);
        
        assert!(final_collateral6 == 0, 0);
        assert!(final_debt6 == 0, 0);
        assert!(!active6_after, 0);
        
        assert!(final_collateral10 == 0, 0);
        assert!(final_debt10 == 0, 0);
        assert!(!active10_after, 0);
        
        // Verify collateral was returned
        assert!(coin::balance<Coin6Decimals>(@0x123) == initial_token_balance1 + initial_collateral6, 0);
        assert!(coin::balance<Coin10Decimals>(@0x456) == initial_token_balance2 + initial_collateral10, 0);
        
        // Check total stats for both collateral types
        let (total_collateral6, total_debt6) = cdp_multi::get_total_stats<Coin6Decimals>();
        let (total_collateral10, total_debt10) = cdp_multi::get_total_stats<Coin10Decimals>();
        
        assert!(total_collateral6 == 0, 0);
        assert!(total_debt6 == 0, 0);
        assert!(total_collateral10 == 0, 0);
        assert!(total_debt10 == 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = cdp_multi)] // err_insufficient_debt_balance (7)
    fun test_close_trove_insufficient_balance() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral for testing
        mint_test_coins<Coin8Decimals>(@cdp, &user, 2000 * math64::pow(10, 8));
        
        // Open a trove
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens
            500 * math64::pow(10, 8)   // 500 debtToken
        );
        
        // Spend all debtToken to make closing fail (don't mint additional debtToken)
        let debtToken_balance = coin::balance<CASH>(@0x123);
        
        // Create a separate account to transfer debtToken
        let receiver = account::create_account_for_test(@0x789);
        coin::register<CASH>(&receiver);
        
        // Transfer all debtToken away from user
        coin::transfer<CASH>(&user, @0x789, debtToken_balance);
        
        // Try to close the trove - this should fail because user doesn't have enough debtToken to cover debt
        cdp_multi::close_trove<Coin8Decimals>(&user);
    }

    #[test]
    fun test_repay_or_withdraw_different_collateral_types() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        let user_addr = signer::address_of(&user);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register for all collateral types
        coin::register<Coin6Decimals>(&user);
        coin::register<Coin8Decimals>(&user);
        coin::register<Coin10Decimals>(&user);
        coin::register<CASH>(&user);
        
        // Register fee collector
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin6Decimals>(@cdp, &user, 10000 * math64::pow(10, 6));
        mint_test_coins<Coin8Decimals>(@cdp, &user, 5000 * math64::pow(10, 8));
        mint_test_coins<Coin10Decimals>(@cdp, &user, 20000 * math64::pow(10, 10));
        
        // Open troves with each collateral type
        cdp_multi::open_trove<Coin6Decimals>(
            &user,
            5000 * math64::pow(10, 6),  // 5000 tokens with 6 decimals at $1.00 = $5,000
            1000 * math64::pow(10, 8)   // 1000 debtToken
        );
        
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            2500 * math64::pow(10, 8),  // 2500 tokens with 8 decimals at $2.00 = $5,000
            1000 * math64::pow(10, 8)   // 1000 debtToken
        );
        
        cdp_multi::open_trove<Coin10Decimals>(
            &user,
            10000 * math64::pow(10, 10), // 10000 tokens with 10 decimals at $0.50 = $5,000
            1000 * math64::pow(10, 8)    // 1000 debtToken
        );
        
        // Get initial positions
        let (initial_coll6, initial_debt6, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (initial_coll8, initial_debt8, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let (initial_coll10, initial_debt10, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x123);
        
        // Perform deposit and mint with all three collateral types
        cdp_multi::deposit_or_mint<Coin6Decimals>(
            &user,
            1000 * math64::pow(10, 6),  // Deposit 1000 tokens
            200 * math64::pow(10, 8)    // Mint 200 debtToken
        );
        
        cdp_multi::deposit_or_mint<Coin8Decimals>(
            &user,
            500 * math64::pow(10, 8),   // Deposit 500 tokens
            200 * math64::pow(10, 8)    // Mint 200 debtToken
        );
        
        cdp_multi::deposit_or_mint<Coin10Decimals>(
            &user,
            2000 * math64::pow(10, 10), // Deposit 2000 tokens
            200 * math64::pow(10, 8)    // Mint 200 debtToken
        );
        
        // Verify positions after deposits
        let (mid_coll6, mid_debt6, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (mid_coll8, mid_debt8, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let (mid_coll10, mid_debt10, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x123);
        
        assert!(mid_coll6 == initial_coll6 + 1000 * math64::pow(10, 6), 0);
        assert!(mid_coll8 == initial_coll8 + 500 * math64::pow(10, 8), 0);
        assert!(mid_coll10 == initial_coll10 + 2000 * math64::pow(10, 10), 0);
        
        assert!(mid_debt6 > initial_debt6, 0);
        assert!(mid_debt8 > initial_debt8, 0);
        assert!(mid_debt10 > initial_debt10, 0);
        
        // Make sure we have enough debtToken for repayments
        cdp_multi::mint_debtToken_for_test(user_addr, 1000 * math64::pow(10, 8));
        
        // Perform repay and withdraw with all three collateral types
        cdp_multi::repay_or_withdraw<Coin6Decimals>(
            &user,
            500 * math64::pow(10, 6),  // Withdraw 500 tokens
            300 * math64::pow(10, 8)   // Repay 300 debtToken
        );
        
        cdp_multi::repay_or_withdraw<Coin8Decimals>(
            &user,
            300 * math64::pow(10, 8),  // Withdraw 300 tokens
            300 * math64::pow(10, 8)   // Repay 300 debtToken
        );
        
        cdp_multi::repay_or_withdraw<Coin10Decimals>(
            &user,
            1000 * math64::pow(10, 10), // Withdraw 1000 tokens
            300 * math64::pow(10, 8)    // Repay 300 debtToken
        );
        
        // Verify final positions
        let (final_coll6, final_debt6, final_active6) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (final_coll8, final_debt8, final_active8) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        let (final_coll10, final_debt10, final_active10) = cdp_multi::get_user_position<Coin10Decimals>(@0x123);
        
        assert!(final_coll6 == mid_coll6 - 500 * math64::pow(10, 6), 0);
        assert!(final_coll8 == mid_coll8 - 300 * math64::pow(10, 8), 0);
        assert!(final_coll10 == mid_coll10 - 1000 * math64::pow(10, 10), 0);
        
        assert!(final_debt6 == mid_debt6 - 300 * math64::pow(10, 8), 0);
        assert!(final_debt8 == mid_debt8 - 300 * math64::pow(10, 8), 0);
        assert!(final_debt10 == mid_debt10 - 300 * math64::pow(10, 8), 0);
        
        assert!(final_active6, 0); // All positions should still be active
        assert!(final_active8, 0);
        assert!(final_active10, 0);
    }

    #[test]
    fun test_liquidate_basic() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register accounts for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        coin::register<Coin8Decimals>(&liquidator);
        coin::register<CASH>(&liquidator);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 1000 * math64::pow(10, 8));
        
        // Open a trove
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens at $2.00 = $2,000
            1000 * math64::pow(10, 8)  // 1000 debtToken (debt)
        );
        
        // Get CDP configuration to determine exact thresholds and fees
        let (_, _, _, liquidation_reserve,liquidation_threshold, _, _,  _, _, _) = 
            cdp_multi::get_collateral_config<Coin8Decimals>();
        
        // Get actual position data including liquidation reserve
        let (initial_collateral, actual_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        // Calculate price that will trigger liquidation (below liquidation threshold)
        let max_price_for_liquidation = ((liquidation_threshold as u128) * (actual_debt as u128)) / 
                                       ((initial_collateral as u128) * 10000);
        let price_for_liquidation = ((max_price_for_liquidation as u64) * 7) / 10; // 70% of max to ensure we're below
        
        // Drop the price to make the position liquidatable
        cdp_multi::set_price<Coin8Decimals>(&admin, price_for_liquidation);
        
        // Give liquidator enough debtToken to perform liquidation
        cdp_multi::mint_debtToken_for_test(@0x456, actual_debt + 100 * math64::pow(10, 8)); // Extra buffer
        
        // Get initial balances
        let initial_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let initial_liquidator_collateral = coin::balance<Coin8Decimals>(@0x456);
        let initial_user_collateral = coin::balance<Coin8Decimals>(@0x123);
        let initial_fee_collector_collateral = coin::balance<Coin8Decimals>(FEE_COLLECTOR);

        debug::print(&(std::string::utf8(b"initial_liquidator_debtToken"))); 
        debug::print(&(initial_liquidator_debtToken));

        std::debug::print(&(std::string::utf8(b"actual_debt"))); 
        debug::print(&(actual_debt));
        
        // Execute liquidation
        cdp_multi::liquidate<Coin8Decimals>(
            &liquidator,
            @0x123
        );
        
        // Verify position was liquidated
        let (final_collateral, final_debt, active) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(final_collateral == 0, 0);
        assert!(final_debt == 0, 0);
        assert!(!active, 0);
        
        // Verify balances after liquidation
        let final_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let final_liquidator_collateral = coin::balance<Coin8Decimals>(@0x456);
        let final_user_collateral = coin::balance<Coin8Decimals>(@0x123);
        let final_fee_collector_collateral = coin::balance<Coin8Decimals>(FEE_COLLECTOR);

        // debug::print(&(std::string::utf8(b"final_liquidator_debtToken"))); 
        // debug::print(&(final_liquidator_debtToken));

        // std::debug::print(&(std::string::utf8(b"final_debt"))); 
        // debug::print(&(final_debt));

        // debug::print(&(std::string::utf8(b"initial_liquidator_debtToken - final_liquidator_debtToken"))); 
        // debug::print(&(initial_liquidator_debtToken - final_liquidator_debtToken));

        // std::debug::print(&(std::string::utf8(b"actual_debt - liquidation_reserve"))); 
        // debug::print(&(actual_debt - liquidation_reserve));
        
        // Liquidator pays debt but gets liquidation reserve back
        let actual_difference = initial_liquidator_debtToken - final_liquidator_debtToken;
        let expected_difference = actual_debt - liquidation_reserve;
        let diff = if (actual_difference > expected_difference) {
            actual_difference - expected_difference
        } else {
            expected_difference - actual_difference
        };
        // Allow for a small rounding error (0.01% should be safe)
        let tolerance = expected_difference / 10000;
        assert!(diff <= tolerance, 0);
        
        // Liquidator should have received collateral
        assert!(final_liquidator_collateral > initial_liquidator_collateral, 0);
        
        // Collateral distribution
        let liquidator_received = final_liquidator_collateral - initial_liquidator_collateral;
        let fee_collector_received = final_fee_collector_collateral - initial_fee_collector_collateral;
        let user_refund = final_user_collateral - initial_user_collateral;
        
        // Verify the total distribution matches initial collateral (within rounding)
        let total_distributed = liquidator_received + fee_collector_received + user_refund;
        
        // Allow for minimal rounding errors (1 unit at the lowest decimal place)
        let diff = if (total_distributed > initial_collateral) {
            total_distributed - initial_collateral
        } else {
            initial_collateral - total_distributed
        };
        
        assert!(diff <= 1, 0);
        
        // Verify total stats were updated
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<Coin8Decimals>();
        assert!(total_collateral == 0, 0);
        assert!(total_debt == 0, 0);
    }


    #[test]
    fun test_liquidate_different_precisions() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user1 = account::create_account_for_test(@0x123);
        let user2 = account::create_account_for_test(@0x234);
        let user3 = account::create_account_for_test(@0x345);
        let liquidator = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register accounts for coins
        coin::register<Coin6Decimals>(&user1);
        coin::register<Coin8Decimals>(&user2);
        coin::register<Coin10Decimals>(&user3);
        coin::register<CASH>(&user1);
        coin::register<CASH>(&user2);
        coin::register<CASH>(&user3);
        coin::register<Coin6Decimals>(&liquidator);
        coin::register<Coin8Decimals>(&liquidator);
        coin::register<Coin10Decimals>(&liquidator);
        coin::register<CASH>(&liquidator);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin6Decimals>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        coin::register<Coin10Decimals>(&fee_collector);
        
        // Mint collateral to users
        mint_test_coins<Coin6Decimals>(@cdp, &user1, 2000 * math64::pow(10, 6));
        mint_test_coins<Coin8Decimals>(@cdp, &user2, 1000 * math64::pow(10, 8));
        mint_test_coins<Coin10Decimals>(@cdp, &user3, 4000 * math64::pow(10, 10));
        
        // Open troves with each collateral type
        cdp_multi::open_trove<Coin6Decimals>(
            &user1,
            2000 * math64::pow(10, 6), // 2000 tokens with 6 decimals
            1000 * math64::pow(10, 8)  // 1000 debtToken with 8 decimals
        );
        
        cdp_multi::open_trove<Coin8Decimals>(
            &user2,
            1000 * math64::pow(10, 8), // 1000 tokens with 8 decimals
            1000 * math64::pow(10, 8)  // 1000 debtToken with 8 decimals
        );
        
        cdp_multi::open_trove<Coin10Decimals>(
            &user3,
            4000 * math64::pow(10, 10), // 4000 tokens with 10 decimals
            1000 * math64::pow(10, 8)   // 1000 debtToken with 8 decimals
        );
        
        // Get CDP configurations
        let (_, _, _,liquidation_reserve6, liquid_threshold6, _, _,  _, _, _) = 
            cdp_multi::get_collateral_config<Coin6Decimals>();
        let (_, _, _,liquidation_reserve8, liquid_threshold8, _, _,  _, _, _) = 
            cdp_multi::get_collateral_config<Coin8Decimals>();
        let (_, _, _,liquidation_reserve10, liquid_threshold10, _, _,  _, _, _) = 
            cdp_multi::get_collateral_config<Coin10Decimals>();

        
        // Get actual position data including fees and liquidation reserves
        let (coll1, debt1, _) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (coll2, debt2, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x234);
        let (coll3, debt3, _) = cdp_multi::get_user_position<Coin10Decimals>(@0x345);
        
        // Calculate prices that will trigger liquidation for each collateral type
        // For Coin6Decimals (6 decimals < 8 decimals of debtToken)
        let price1 = ((liquid_threshold6 as u128) * (debt1 as u128) * (math64::pow(10, 2) as u128)) / 
                    ((coll1 as u128) * 10000);
        
        // For Coin8Decimals (8 decimals = 8 decimals of debtToken)
        let price2 = ((liquid_threshold8 as u128) * (debt2 as u128)) / 
                    ((coll2 as u128) * 10000);
        
        // For Coin10Decimals (10 decimals > 8 decimals of debtToken)
        let price3 = ((liquid_threshold10 as u128) * (debt3 as u128)) / 
                    (((coll3 as u128) * 10000) * (math64::pow(10, 2) as u128));
        
        // Set prices below threshold to make positions liquidatable - use 70% instead of 90% to 
        // ensure we're well below the threshold
        cdp_multi::set_price<Coin6Decimals>(&admin, ((price1 as u64) * 7) / 10); 
        cdp_multi::set_price<Coin8Decimals>(&admin, ((price2 as u64) * 7) / 10);
        cdp_multi::set_price<Coin10Decimals>(&admin, ((price3 as u64) * 7) / 10);
        
        // Give liquidator enough debtToken for all liquidations
        cdp_multi::mint_debtToken_for_test(@0x456, debt1 + debt2 + debt3 + 100 * math64::pow(10, 8));
        
        // Get initial balances
        let initial_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let initial_liquidator_coll6 = coin::balance<Coin6Decimals>(@0x456);
        let initial_liquidator_coll8 = coin::balance<Coin8Decimals>(@0x456);
        let initial_liquidator_coll10 = coin::balance<Coin10Decimals>(@0x456);
        let initial_user1_coll = coin::balance<Coin6Decimals>(@0x123);
        let initial_user2_coll = coin::balance<Coin8Decimals>(@0x234);
        let initial_user3_coll = coin::balance<Coin10Decimals>(@0x345);
        let initial_fee_coll6 = coin::balance<Coin6Decimals>(FEE_COLLECTOR);
        let initial_fee_coll8 = coin::balance<Coin8Decimals>(FEE_COLLECTOR);
        let initial_fee_coll10 = coin::balance<Coin10Decimals>(FEE_COLLECTOR);
        
        // Execute liquidations for each collateral type
        cdp_multi::liquidate<Coin6Decimals>(&liquidator, @0x123);
        cdp_multi::liquidate<Coin8Decimals>(&liquidator, @0x234);
        cdp_multi::liquidate<Coin10Decimals>(&liquidator, @0x345);
        
        // Verify positions were liquidated
        let (_, _, active1) = cdp_multi::get_user_position<Coin6Decimals>(@0x123);
        let (_, _, active2) = cdp_multi::get_user_position<Coin8Decimals>(@0x234);
        let (_, _, active3) = cdp_multi::get_user_position<Coin10Decimals>(@0x345);
        
        assert!(!active1, 0);
        assert!(!active2, 0);
        assert!(!active3, 0);
        
        // Get final balances
        let final_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let final_liquidator_coll6 = coin::balance<Coin6Decimals>(@0x456);
        let final_liquidator_coll8 = coin::balance<Coin8Decimals>(@0x456);
        let final_liquidator_coll10 = coin::balance<Coin10Decimals>(@0x456);
        let final_user1_coll = coin::balance<Coin6Decimals>(@0x123);
        let final_user2_coll = coin::balance<Coin8Decimals>(@0x234);
        let final_user3_coll = coin::balance<Coin10Decimals>(@0x345);
        let final_fee_coll6 = coin::balance<Coin6Decimals>(FEE_COLLECTOR);
        let final_fee_coll8 = coin::balance<Coin8Decimals>(FEE_COLLECTOR);
        let final_fee_coll10 = coin::balance<Coin10Decimals>(FEE_COLLECTOR);
        
        // Liquidator pays debt but gets liquidation reserve back (for all three positions)
        assert!(initial_liquidator_debtToken - final_liquidator_debtToken == 
                (debt1 + debt2 + debt3) - (liquidation_reserve6 + liquidation_reserve8 + liquidation_reserve10), 0);
        
        // Check collateral distribution for all tokens
        let liquidator6_received = final_liquidator_coll6 - initial_liquidator_coll6;
        let fee6_received = final_fee_coll6 - initial_fee_coll6;
        let user1_refund = final_user1_coll - initial_user1_coll;
        let total_distributed6 = liquidator6_received + fee6_received + user1_refund;
        
        let liquidator8_received = final_liquidator_coll8 - initial_liquidator_coll8;
        let fee8_received = final_fee_coll8 - initial_fee_coll8;
        let user2_refund = final_user2_coll - initial_user2_coll;
        let total_distributed8 = liquidator8_received + fee8_received + user2_refund;
        
        let liquidator10_received = final_liquidator_coll10 - initial_liquidator_coll10;
        let fee10_received = final_fee_coll10 - initial_fee_coll10;
        let user3_refund = final_user3_coll - initial_user3_coll;
        let total_distributed10 = liquidator10_received + fee10_received + user3_refund;
        
        // Verify distributions match initial collateral (within rounding)
        let diff6 = if (total_distributed6 > coll1) {
            total_distributed6 - coll1
        } else {
            coll1 - total_distributed6
        };
        
        let diff8 = if (total_distributed8 > coll2) {
            total_distributed8 - coll2
        } else {
            coll2 - total_distributed8
        };
        
        let diff10 = if (total_distributed10 > coll3) {
            total_distributed10 - coll3
        } else {
            coll3 - total_distributed10
        };
        
        assert!(diff6 <= 10, 0);
        assert!(diff8 <= 1, 0);
        assert!(diff10 <= 100, 0);
        
        // Verify total stats
        let (total_coll6, total_debt6) = cdp_multi::get_total_stats<Coin6Decimals>();
        let (total_coll8, total_debt8) = cdp_multi::get_total_stats<Coin8Decimals>();
        let (total_coll10, total_debt10) = cdp_multi::get_total_stats<Coin10Decimals>();
        
        assert!(total_coll6 == 0, 0);
        assert!(total_debt6 == 0, 0);
        assert!(total_coll8 == 0, 0);
        assert!(total_debt8 == 0, 0);
        assert!(total_coll10 == 0, 0);
        assert!(total_debt10 == 0, 0);
    }

    #[test]
    fun test_liquidate_above_100_percent_icr() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register accounts for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        coin::register<Coin8Decimals>(&liquidator);
        coin::register<CASH>(&liquidator);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 2000 * math64::pow(10, 8));
        
        // Open a trove
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            2000 * math64::pow(10, 8), // 2000 tokens at $2.00 = $4,000
            2000 * math64::pow(10, 8)  // 2000 debtToken (debt)
        );

        let (_, _, _,liquidation_reserve, liquid_threshold, liquidation_penalty, _,  _, liquidation_fee_protocol, _) = 
            cdp_multi::get_collateral_config<Coin8Decimals>();
        
        debug::print(&std::string::utf8(b"Liquidation threshold:"));
        debug::print(&liquid_threshold);
        debug::print(&std::string::utf8(b"Liquidation penalty:"));
        debug::print(&liquidation_penalty);
        debug::print(&std::string::utf8(b"Liquidation fee protocol %:"));
        debug::print(&liquidation_fee_protocol);
        
        // Get actual position data including liquidation reserve
        let (initial_collateral, actual_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        debug::print(&std::string::utf8(b"Initial collateral amount:"));
        debug::print(&initial_collateral);
        debug::print(&std::string::utf8(b"Initial debt amount:"));
        debug::print(&actual_debt);
        
        // Set a much higher price - 105% of debt / collateral
        // For 2000 tokens and ~2050 debt, we need approximately $1.05 per token
        // At 8 decimals, that's 105,000,000
        let price = 105000000;
        
        debug::print(&std::string::utf8(b"Setting price to:"));
        debug::print(&price);
        
        cdp_multi::set_price<Coin8Decimals>(&admin, price);
        
        // Verify the price was set correctly
        let actual_price = cdp_multi::get_collateral_price_raw<Coin8Decimals>();
        debug::print(&std::string::utf8(b"Actual price set in contract:"));
        debug::print(&actual_price);
        
        // Calculate what the expected ICR should be
        let expected_icr = ((initial_collateral as u128) * (actual_price as u128) * 10000) / 
                           ((actual_debt as u128) * 100000000); // Price has 8 decimals
        debug::print(&std::string::utf8(b"Expected ICR calculation:"));
        debug::print(&expected_icr);
        
        // Give liquidator enough debtToken
        cdp_multi::mint_debtToken_for_test(@0x456, actual_debt + 100 * math64::pow(10, 8));
        
        // Get balances before liquidation
        let initial_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let initial_liquidator_collateral = coin::balance<Coin8Decimals>(@0x456);
        let initial_user_collateral = coin::balance<Coin8Decimals>(@0x123);
        let initial_fee_collector_collateral = coin::balance<Coin8Decimals>(FEE_COLLECTOR);
        
        debug::print(&std::string::utf8(b"Initial liquidator debtToken:"));
        debug::print(&initial_liquidator_debtToken);
        debug::print(&std::string::utf8(b"Initial fee collector collateral:"));
        debug::print(&initial_fee_collector_collateral);
        
        // Execute liquidation
        cdp_multi::liquidate<Coin8Decimals>(
            &liquidator,
            @0x123
        );

        // Verify position was liquidated
        let (final_collateral, final_debt, active) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(final_collateral == 0, 0);
        assert!(final_debt == 0, 0);
        assert!(!active, 0);
        
        // Verify balances after liquidation
        let final_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let final_liquidator_collateral = coin::balance<Coin8Decimals>(@0x456);
        let final_user_collateral = coin::balance<Coin8Decimals>(@0x123);
        let final_fee_collector_collateral = coin::balance<Coin8Decimals>(FEE_COLLECTOR);
        
        debug::print(&std::string::utf8(b"Final fee collector collateral:"));
        debug::print(&final_fee_collector_collateral);
        
        // KEY CHANGE: Liquidator pays debt but gets liquidation reserve back
        assert!(initial_liquidator_debtToken - final_liquidator_debtToken == actual_debt - liquidation_reserve, 0);
        
        // Verify protocol fee was collected (should be non-zero since ICR > 100%)
        let protocol_fee_received = final_fee_collector_collateral - initial_fee_collector_collateral;
        debug::print(&std::string::utf8(b"Protocol fee received:"));
        debug::print(&protocol_fee_received);
        
        // Implement a conditional check based on the calculated ICR
        if (expected_icr > 10000) {
            // If ICR > 100%, we should have a protocol fee
            assert!(protocol_fee_received > 0, 0);
        } else {
            // If ICR <= 100%, no protocol fee is expected
            debug::print(&std::string::utf8(b"ICR is underwater, no protocol fee expected"));
        };
        
        // User might receive a refund since ICR > 100%
        let user_refund = final_user_collateral - initial_user_collateral;
        debug::print(&std::string::utf8(b"User refund:"));
        debug::print(&user_refund);
        
        // Liquidator received portion of collateral
        let liquidator_received = final_liquidator_collateral - initial_liquidator_collateral;
        debug::print(&std::string::utf8(b"Liquidator received:"));
        debug::print(&liquidator_received);
        assert!(liquidator_received > 0, 0);
        
        // Verify total distribution equals initial collateral
        let total_distributed = liquidator_received + protocol_fee_received + user_refund;
        debug::print(&std::string::utf8(b"Total distributed vs initial collateral:"));
        debug::print(&total_distributed);
        debug::print(&initial_collateral);
        
        // Allow for rounding errors
        let diff = if (total_distributed > initial_collateral) {
            total_distributed - initial_collateral
        } else {
            initial_collateral - total_distributed
        };
        
        debug::print(&std::string::utf8(b"Distribution difference:"));
        debug::print(&diff);
        assert!(diff <= 10, 0);
        
        // Verify total stats
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<Coin8Decimals>();
        assert!(total_collateral == 0, 0);
        assert!(total_debt == 0, 0);
    }

    #[test]
    fun test_liquidate_large_numbers() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register accounts for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        coin::register<Coin8Decimals>(&liquidator);
        coin::register<CASH>(&liquidator);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint large amount of collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 10000000 * math64::pow(10, 8)); // 10M tokens
        
        // Open a trove with large values
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            10000000 * math64::pow(10, 8), // 10M tokens at $2.00 = $20M
            5000000 * math64::pow(10, 8)   // 5M debtToken (debt)
        );
        
        // Get CDP configuration
        let (_, _, _, liquidation_reserve, liquidation_threshold, _, _, _, _, _) = 
            cdp_multi::get_collateral_config<Coin8Decimals>();
        
        // Get actual position data including liquidation reserve
        let (initial_collateral, actual_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        // Calculate price that will trigger liquidation (based on actual debt which includes fees)
        let threshold_price = ((liquidation_threshold as u128) * (actual_debt as u128)) / 
                            ((initial_collateral as u128) * 10000);
        
        // Use 70% of threshold to ensure liquidation is possible
        let liquidation_price = ((threshold_price as u64) * 70) / 100;
        
        // Set price to trigger liquidation
        cdp_multi::set_price<Coin8Decimals>(&admin, liquidation_price);
        
        // Give liquidator enough debtToken
        cdp_multi::mint_debtToken_for_test(@0x456, actual_debt + 100 * math64::pow(10, 8));
        
        // Get balances before liquidation
        let initial_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let initial_liquidator_collateral = coin::balance<Coin8Decimals>(@0x456);
        let initial_user_collateral = coin::balance<Coin8Decimals>(@0x123);
        let initial_fee_collector_collateral = coin::balance<Coin8Decimals>(FEE_COLLECTOR);
        
        // Execute liquidation
        cdp_multi::liquidate<Coin8Decimals>(
            &liquidator,
            @0x123
        );
        
        // Verify position was liquidated
        let (final_collateral, final_debt, active) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        assert!(final_collateral == 0, 0);
        assert!(final_debt == 0, 0);
        assert!(!active, 0);
        
        // Verify balances after liquidation
        let final_liquidator_debtToken = coin::balance<CASH>(@0x456);
        let final_liquidator_collateral = coin::balance<Coin8Decimals>(@0x456);
        let final_user_collateral = coin::balance<Coin8Decimals>(@0x123);
        let final_fee_collector_collateral = coin::balance<Coin8Decimals>(FEE_COLLECTOR);

        // std::debug::print(&(std::string::utf8(b"Expected remaining debt"))); 
        // debug::print(&(actual_debt - liquidation_reserve));

        // std::debug::print(&(std::string::utf8(b"initial_liquidator_debtToken - final_liquidator_debtToken"))); 
        // debug::print(&(initial_liquidator_debtToken - final_liquidator_debtToken));

        // KEY CHANGE: Liquidator pays debt but gets liquidation reserve back
        assert!(initial_liquidator_debtToken - final_liquidator_debtToken == actual_debt - liquidation_reserve, 0);
        
        // Calculate distribution amounts
        let liquidator_received = final_liquidator_collateral - initial_liquidator_collateral;
        let fee_received = final_fee_collector_collateral - initial_fee_collector_collateral;
        let user_refund = final_user_collateral - initial_user_collateral;
        
        // For such a low price and large numbers, we expect liquidator to receive most/all
        assert!(liquidator_received > 0, 0);
        
        // Sum of distributions should equal initial collateral
        let total_distributed = liquidator_received + fee_received + user_refund;
        
        // Allow for rounding errors with large numbers
        let diff = if (total_distributed > initial_collateral) {
            total_distributed - initial_collateral
        } else {
            initial_collateral - total_distributed
        };
        
        // For large numbers, allow slightly larger rounding error
        assert!(diff <= 100, 0);
        
        // Verify total stats
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<Coin8Decimals>();
        assert!(total_collateral == 0, 0);
        assert!(total_debt == 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = 9, location = cdp::cdp_multi)] // err_cannot_liquidate
    fun test_liquidate_fails_above_threshold() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        let liquidator = account::create_account_for_test(@0x456);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register accounts for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        coin::register<Coin8Decimals>(&liquidator);
        coin::register<CASH>(&liquidator);
        
        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);
        
        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 1000 * math64::pow(10, 8));
        
        // Open a trove
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens at $2.00 = $2,000
            1000 * math64::pow(10, 8)  // 1000 debtToken (debt)
        );
        
        // Get CDP configuration
        let (_, _, _, _, liquidation_threshold, _, _, _, _, _) = cdp_multi::get_collateral_config<Coin8Decimals>();
        
        // Get actual position data including liquidation reserve
        let (initial_collateral, actual_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        // Calculate price that keeps position just above liquidation threshold
        // let threshold_price = ((liquidation_threshold as u128) * (actual_debt as u128)) / 
        //                     ((initial_collateral as u128) * 10000);
        
        // // Use 110% of threshold to ensure we're above it
        // let safe_price = ((threshold_price as u64) * 117) / 100
        // // Set price to keep position safe
        // cdp_multi::set_price<Coin8Decimals>(&admin, safe_price);
        
        // Give liquidator enough debtToken
        cdp_multi::mint_debtToken_for_test(@0x456, actual_debt);
        
        // Try to liquidate - should fail because ICR > liquidation threshold
        cdp_multi::liquidate<Coin8Decimals>(
            &liquidator,
            @0x123
        );
    }

    #[test]
    #[expected_failure(abort_code = 19, location = cdp::cdp_multi)] // err_self_liquidation
    fun test_liquidate_fails_self_liquidation() acquires MintCapabilities {
        let aptos_framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        
        block::initialize_for_test(&aptos_framework, 1);
        setup_test(&aptos_framework, &admin);
        
        // Register account for coins
        coin::register<Coin8Decimals>(&user);
        coin::register<CASH>(&user);
        
        coin::register<Coin8Decimals>(&admin);
        coin::register<CASH>(&admin);

        // Register fee collector for coins
        let fee_collector = account::create_signer_for_test(FEE_COLLECTOR);
        coin::register<CASH>(&fee_collector);
        coin::register<Coin8Decimals>(&fee_collector);

        // Mint collateral to user
        mint_test_coins<Coin8Decimals>(@cdp, &user, 1000 * math64::pow(10, 8));
        
        // Open a trove
        cdp_multi::open_trove<Coin8Decimals>(
            &user,
            1000 * math64::pow(10, 8), // 1000 tokens at $2.00 = $2,000
            1000 * math64::pow(10, 8)  // 1000 debtToken (debt)
        );
        
        // Get CDP configuration
        let (_, _, _, liquidation_threshold, _, _, _, _, _, _) = cdp_multi::get_collateral_config<Coin8Decimals>();
        
        // Get actual position data including liquidation reserve
        let (initial_collateral, actual_debt, _) = cdp_multi::get_user_position<Coin8Decimals>(@0x123);
        
        // Calculate price that will trigger liquidation
        let threshold_price = ((liquidation_threshold as u128) * (actual_debt as u128)) / 
                            ((initial_collateral as u128) * 10000);
        
        // Set price below threshold
        cdp_multi::set_price<Coin8Decimals>(&admin, ((threshold_price as u64) * 9) / 10);
        
        // Try to self-liquidate - should fail
        cdp_multi::liquidate<Coin8Decimals>(
            &user,
            @0x123
        );
    }
}