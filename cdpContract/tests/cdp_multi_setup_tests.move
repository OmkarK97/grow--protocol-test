#[test_only]
module cdp::cdp_multi_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::account;
    use supra_framework::block;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use cdp::cdp_multi;
    use cdp::price_oracle;
    use cdp::events;
    use cdp::config;
    // use cdp::mock_oracle;
    use cdp::cdp_multi::CASH;
    use std::fixed_point32;
    use supra_framework::timestamp;
    use supra_framework::debug;
    


    // Test coins for multi-collateral testing
    struct TestCoin has key {}
    struct TestCoin2 has key {}
    struct TestCoin3 has key {}

    // Constants for SUPRA configuration
    const SUPRA_MCR: u64 = 13000; // 130%
    const SUPRA_MIN_DEBT: u64 = 25 * 100000000; // 25 units
    const SUPRA_LIQ_THRESHOLD: u64 = 12000; // 120%
    const FEE_COLLECTOR: address = @0x2db5c23e86ef48e8604685b14017a3c2625484ebf33d84d80c4541daf44c459a;
    const DECIMALS: u8 = 8;
    const SCALING_FACTOR: u64 = 100000000; // 10^8
    const DEFAULT_MCR: u64 = 12500; // 125%
    const DEFAULT_BORROW_RATE: u64 = 200; // 2%
    const DEFAULT_MIN_DEBT: u64 = 20 * 100000000; // 20 units
    const DEFAULT_LIQ_RESERVE: u64 = 2 * 100000000; // 2 units
    const DEFAULT_LIQ_THRESHOLD: u64 = 11500; // 115%
    const DEFAULT_LIQ_PENALTY: u64 = 1000; // 10%
    const DEFAULT_REDEMPTION_FEE: u64 = 50; // 0.5%
    const DEFAULT_LIQ_FEE_PROTOCOL: u64 = 100; // 1%
    const DEFAULT_REDEMPTION_FEE_GRATUITY: u64 = 100; // 1%
    // Helper function to create admin account
    fun get_admin_account(): signer {
        account::create_account_for_test(@cdp)
    }

    // Helper function to setup test coin
    fun initialize_test_coin(admin: &signer): (coin::BurnCapability<TestCoin>, coin::MintCapability<TestCoin>) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );
        coin::destroy_freeze_cap(freeze_cap);
        (burn_cap, mint_cap)
    }

    // Helper function to setup test coin 2
    fun initialize_test_coin2(admin: &signer): (coin::BurnCapability<TestCoin2>, coin::MintCapability<TestCoin2>) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin2>(
            admin,
            string::utf8(b"Test Coin 2"),
            string::utf8(b"TEST2"),
            DECIMALS,
            true
        );
        coin::destroy_freeze_cap(freeze_cap);
        (burn_cap, mint_cap)
    }

    // Helper function for basic initialization
    fun setup_basic(): (signer, signer) {
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        
        // Initialize SupraCoin first
        let (supra_burn_cap, supra_mint_cap) = supra_coin::initialize_for_test(&framework);
        coin::destroy_burn_cap(supra_burn_cap);
        coin::destroy_mint_cap(supra_mint_cap);

        // Initialize TestCoin with admin account
        let (burn_cap, mint_cap) = initialize_test_coin(&admin);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        // Initialize TestCoin2
        let (burn_cap2, mint_cap2) = initialize_test_coin2(&admin);
        coin::destroy_burn_cap(burn_cap2);
        coin::destroy_mint_cap(mint_cap2);
        
        // Initialize CDP system
        cdp_multi::initialize(&admin, FEE_COLLECTOR);

        // let supra = account::create_account_for_test(@0x5615001f63d3223f194498787647bb6f8d37b8d1e6773c00dcdd894079e56190);
        // mock_oracle::initialize(&admin);
        (framework, admin)
    }

    // Helper function to setup multiple collaterals
    fun setup_multi_collateral(admin: &signer) {
        // Setup TestCoin as first collateral
        cdp_multi::add_collateral<TestCoin>(
            admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );

        // Setup TestCoin2 as second collateral
        cdp_multi::add_collateral<TestCoin2>(
            admin,
            DEFAULT_MIN_DEBT * 2,
            DEFAULT_MCR + 500,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD + 500,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            2,
            900
        );

        // Setup SUPRA as premium collateral
        cdp_multi::add_collateral<SupraCoin>(
            admin,
            SUPRA_MIN_DEBT,
            SUPRA_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            SUPRA_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            3,
            900
        );

        // Set initial prices
        // set_mock_price( 10 * SCALING_FACTOR, 1);
        // set_mock_price( 20 * SCALING_FACTOR, 2);
        // set_mock_price( 50 * SCALING_FACTOR, 3);
        cdp_multi::set_price<TestCoin>(admin, 10 * SCALING_FACTOR);     // $10
        cdp_multi::set_price<TestCoin2>(admin, 20 * SCALING_FACTOR);    // $20
        cdp_multi::set_price<SupraCoin>(admin, 50 * SCALING_FACTOR);    // $50
    }

    #[test]
    fun test_initialization() {
        let (_framework, _admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Verify debtToken coin initialization
        assert!(coin::is_coin_initialized<CASH>(), 0);
        assert!(coin::name<CASH>() == string::utf8(b"Solido Stablecoin"), 1);
        assert!(coin::symbol<CASH>() == string::utf8(b"CASH"), 2);
        assert!(coin::decimals<CASH>() == 8, 3);
    }

    #[test]
    fun test_add_collateral_config() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Now add it as collateral (TestCoin is already initialized in setup)
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Verify config
        let (min_debt, mcr, borrow_rate, liq_reserve, liq_threshold, liq_penalty, redemption_fee, enabled, liq_fee_protocol, redemption_fee_gratuity) = 
            cdp_multi::get_collateral_config<TestCoin>();
        // std::debug::print(&(std::string::utf8(b"min_debt")));  
        // std::debug::print(&min_debt);
        //verify using is_valid_collateral
        assert!(cdp_multi::is_valid_collateral<TestCoin>(), 0);
        assert!(min_debt == DEFAULT_MIN_DEBT, 0);
        assert!(mcr == DEFAULT_MCR, 1);
        assert!(borrow_rate == DEFAULT_BORROW_RATE, 2);
        assert!(liq_reserve == DEFAULT_LIQ_RESERVE, 3);
        assert!(liq_threshold == DEFAULT_LIQ_THRESHOLD, 4);
        assert!(liq_penalty == DEFAULT_LIQ_PENALTY, 5);
        assert!(redemption_fee == DEFAULT_REDEMPTION_FEE, 6);
        assert!(enabled == true, 7);
    }

    #[test]
    fun test_set_price() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral first
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Set price to 10 USD
        let price = 10 * SCALING_FACTOR;
        cdp_multi::set_price<TestCoin>(&admin, price);
        
        // Verify price
        let stored_price = cdp_multi::get_collateral_price_raw<TestCoin>();
        std::debug::print(&(std::string::utf8(b"stored_price before")));  
        std::debug::print(&stored_price);
        assert!(stored_price == price, 0);
        
        // Set and verify decimal price
        let decimal_price = 15 * SCALING_FACTOR + 50 * SCALING_FACTOR / 100; // 15.50 USD
        cdp_multi::set_price<TestCoin>(&admin, decimal_price);
        let stored_decimal_price = cdp_multi::get_collateral_price_raw<TestCoin>();
        std::debug::print(&(std::string::utf8(b"stored_decimal_price")));  
        std::debug::print(&stored_decimal_price);
        assert!(stored_decimal_price == decimal_price, 1);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_NOT_ADMIN,)]
    fun test_set_price_unauthorized() {
        let (_framework, admin) = setup_basic();
        let unauthorized = account::create_account_for_test(@0x123);
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Try to set price with unauthorized account (should fail)
        cdp_multi::set_price<TestCoin>(&unauthorized, 10 * SCALING_FACTOR);
    }

    #[test]
    fun test_fee_collector_address() {
        let (_framework, _admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        let fee_collector = cdp_multi::get_fee_collector();
        assert!(fee_collector == @0x2db5c23e86ef48e8604685b14017a3c2625484ebf33d84d80c4541daf44c459a, 0);
    }

    #[test]
    fun test_redemption_provider_registration() {
        let (_framework, _admin) = setup_basic();
        let user = account::create_account_for_test(@0x123);
        timestamp::set_time_has_started_for_testing(&_framework);
        // Initially should not be a redemption provider
        assert!(!cdp_multi::is_redemption_provider<TestCoin>(signer::address_of(&user)), 0);
        
        // Register as redemption provider
        cdp_multi::register_as_redemption_provider<TestCoin>(&user, true);
        assert!(cdp_multi::is_redemption_provider<TestCoin>(signer::address_of(&user)), 1);
        
        // Unregister
        cdp_multi::register_as_redemption_provider<TestCoin>(&user, false);
        assert!(!cdp_multi::is_redemption_provider<TestCoin>(signer::address_of(&user)), 2);
    }

    #[test]
    fun test_get_total_stats() {
        let (_framework, _admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Initially should be zero
        let (total_collateral, total_debt) = cdp_multi::get_total_stats<TestCoin>();
        assert!(total_collateral == 0, 0);
        assert!(total_debt == 0, 1);
    }

    #[test]
    fun test_get_user_position() {
        let (_framework, _admin) = setup_basic();
        let user = account::create_account_for_test(@0x123);
        timestamp::set_time_has_started_for_testing(&_framework);
        // Initially should be zero
        let (collateral, debt, active) = cdp_multi::get_user_position<TestCoin>(signer::address_of(&user));
        assert!(collateral == 0, 0);
        assert!(debt == 0, 1);
        assert!(active == false, 2);
    }

    #[test]
    fun test_multi_collateral_setup() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        setup_multi_collateral(&admin);
        // Verify TestCoin configuration
        assert!(cdp_multi::is_valid_collateral<TestCoin>(), 0);
        let (min_debt, mcr, _, _, _, _, _, enabled, _,_) = cdp_multi::get_collateral_config<TestCoin>();
        assert!(min_debt == DEFAULT_MIN_DEBT, 1);
        assert!(mcr == DEFAULT_MCR, 2);
        assert!(enabled == true, 3);
        
        // Verify TestCoin2 configuration
        assert!(cdp_multi::is_valid_collateral<TestCoin2>(), 4);
        let (min_debt2, mcr2, _, _, _, _, _, enabled2, _,_) = cdp_multi::get_collateral_config<TestCoin2>();
        assert!(min_debt2 == DEFAULT_MIN_DEBT * 2, 5);
        assert!(mcr2 == DEFAULT_MCR + 500, 6);
        assert!(enabled2 == true, 7);
        
        // Verify SUPRA configuration
        assert!(cdp_multi::is_valid_collateral<SupraCoin>(), 8);
        let (min_debt3, mcr3, _, _, liq_threshold, _, _, enabled3, _,_) = cdp_multi::get_collateral_config<SupraCoin>();
        assert!(min_debt3 == SUPRA_MIN_DEBT, 9);
        assert!(mcr3 == SUPRA_MCR, 10);
        assert!(liq_threshold == SUPRA_LIQ_THRESHOLD, 11);
        assert!(enabled3 == true, 12);
    }

    #[test]
    fun test_multi_collateral_prices() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        setup_multi_collateral(&admin);
        // Verify initial prices
        let price1 = cdp_multi::get_collateral_price_raw<TestCoin>();
        let price2 = cdp_multi::get_collateral_price_raw<TestCoin2>();
        let price3 = cdp_multi::get_collateral_price_raw<SupraCoin>();

        assert!(price1 == 10 * SCALING_FACTOR, 0);
        assert!(price2 == 20 * SCALING_FACTOR, 1);
        assert!(price3 == 50 * SCALING_FACTOR, 2);

        // Update prices and verify
        cdp_multi::set_price<TestCoin>(&admin, 15 * SCALING_FACTOR);
        cdp_multi::set_price<TestCoin2>(&admin, 25 * SCALING_FACTOR);
        cdp_multi::set_price<SupraCoin>(&admin, 55 * SCALING_FACTOR);

        let new_price1 = cdp_multi::get_collateral_price_raw<TestCoin>();
        let new_price2 = cdp_multi::get_collateral_price_raw<TestCoin2>();
        let new_price3 = cdp_multi::get_collateral_price_raw<SupraCoin>();

        assert!(new_price1 == 15 * SCALING_FACTOR, 3);
        assert!(new_price2 == 25 * SCALING_FACTOR, 4);
        assert!(new_price3 == 55 * SCALING_FACTOR, 5);
    }

    #[test]
    fun test_multi_collateral_stats() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        setup_multi_collateral(&admin);
        // Verify initial stats are zero for all collaterals
        let (tc_coll, tc_debt) = cdp_multi::get_total_stats<TestCoin>();
        let (tc2_coll, tc2_debt) = cdp_multi::get_total_stats<TestCoin2>();
        let (supra_coll, supra_debt) = cdp_multi::get_total_stats<SupraCoin>();

        assert!(tc_coll == 0 && tc_debt == 0, 0);
        assert!(tc2_coll == 0 && tc2_debt == 0, 1);
        assert!(supra_coll == 0 && supra_debt == 0, 2);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_COIN_NOT_INITIALIZED)]
    fun test_add_uninitialized_collateral() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Try to add TestCoin2 without initializing it first
        cdp_multi::add_collateral<TestCoin3>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
    }



    #[test]
    fun test_verify_collateral_ratio_valid() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral with default config
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Set price to $10
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);
        
        // Test cases with valid ratios
        // Case 1: Exactly at MCR (125%)
        // With TestCoin price = 10 USD:
        // 1000 TestCoin = 10000 USD collateral value
        // 8000 debtToken debt requires 10000 USD collateral at 125% MCR
        cdp_multi::verify_collateral_ratio<TestCoin>(1000 * SCALING_FACTOR, 8000 * SCALING_FACTOR);
        
        // Case 2: Well above MCR (200%)
        // 1000 TestCoin = 10000 USD collateral value
        // 5000 debtToken debt = 200% collateralization
        cdp_multi::verify_collateral_ratio<TestCoin>(1000 * SCALING_FACTOR, 5000 * SCALING_FACTOR);
        
        // Case 3: Zero debt (should always pass)
        cdp_multi::verify_collateral_ratio<TestCoin>(100 * SCALING_FACTOR, 0);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_INSUFFICIENT_COLLATERAL)]
    fun test_verify_collateral_ratio_below_mcr() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Set price to $10
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);
        
        // Test case with invalid ratio (100%)
        // 1000 TestCoin = 10000 USD collateral value
        // 10000 debtToken debt would require 12500 USD collateral at 125% MCR
        cdp_multi::verify_collateral_ratio<TestCoin>(1000 * SCALING_FACTOR, 10000 * SCALING_FACTOR);
    }

    #[test]
    fun test_verify_collateral_ratio_edge_cases() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Set price to $10
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);
        
        // Case 1: Zero collateral with zero debt (should pass)
        cdp_multi::verify_collateral_ratio<TestCoin>(0, 0);
        
        // Case 2: Very large collateral amount
        let large_collateral = 1000000 * SCALING_FACTOR; // 1 million TestCoin
        let large_debt = 8000000 * SCALING_FACTOR; // 8 million ORE (maintains 125% ratio)
        cdp_multi::verify_collateral_ratio<TestCoin>(large_collateral, large_debt);
        
        // Case 3: Minimum viable amounts
        // With TestCoin price = 10 USD:
        // 1 TestCoin = 10 USD collateral value
        // 8 debtToken debt requires 10 USD collateral at 125% MCR
        cdp_multi::verify_collateral_ratio<TestCoin>(1 * SCALING_FACTOR, 8 * SCALING_FACTOR);
    }

    #[test]
    fun test_verify_collateral_ratio_calculations() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Set price to $10
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);
        
        // Get the current MCR from config
        let (_, mcr, _, _, _, _, _, _, _,_) = cdp_multi::get_collateral_config<TestCoin>();
        
        // Test with exact MCR ratio
        let collateral = 1000 * SCALING_FACTOR; // 1000 TestCoin
        let debt = 8000 * SCALING_FACTOR; // 8000 debtToken
        
        // Verify the ratio is valid
        cdp_multi::verify_collateral_ratio<TestCoin>(collateral, debt);
        
        // Calculate expected ratio for verification
        let price = cdp_multi::get_collateral_price<TestCoin>();
        let collateral_value = fixed_point32::multiply_u64(collateral, price);
        let ratio = (collateral_value * 10000) / debt;
        
        // Verify ratio is at or above MCR
        assert!(ratio >= mcr, 0);
    }


    #[test]
    fun test_set_config() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // First add TestCoin as collateral with default config
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Update config with new values
        let new_min_debt = 30 * SCALING_FACTOR;
        let new_mcr = 13000; // 130%
        let new_borrow_rate = 300; // 3%
        let new_liq_threshold = 12000; // 120%
        let new_liq_penalty = 1500; // 15%
        let new_redemption_fee = 100; // 1%
        let new_liq_fee_protocol = 200; // 2%
        let new_redemption_fee_gratuity = 200; // 1%
        
        cdp_multi::set_config<TestCoin>(
            &admin,
            new_min_debt,
            new_mcr,
            new_borrow_rate,
            new_liq_threshold,
            new_liq_penalty,
            new_redemption_fee,
            true,
            new_liq_fee_protocol,
            new_redemption_fee_gratuity
        );
        
        // Verify updated config
        let (min_debt, mcr, borrow_rate, liq_reserve, liq_threshold, liq_penalty, redemption_fee, enabled, liq_fee_protocol, redemption_fee_gratuity) = 
            cdp_multi::get_collateral_config<TestCoin>();
            
        assert!(min_debt == new_min_debt, 0);
        assert!(mcr == new_mcr, 1);
        assert!(borrow_rate == new_borrow_rate, 2);
        assert!(liq_reserve == DEFAULT_LIQ_RESERVE, 3); // Should remain unchanged
        assert!(liq_threshold == new_liq_threshold, 4);
        assert!(liq_penalty == new_liq_penalty, 5);
        assert!(redemption_fee == new_redemption_fee, 6);
        assert!(enabled == true, 7);
        assert!(liq_fee_protocol == new_liq_fee_protocol, 8);
        assert!(redemption_fee_gratuity == new_redemption_fee_gratuity, 9);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_NOT_ADMIN)]
    fun test_set_config_unauthorized() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        let unauthorized = account::create_account_for_test(@0x123);
        
        // First add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Try to update config with unauthorized account (should fail)
        cdp_multi::set_config<TestCoin>(
            &unauthorized,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            true,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY
        );
    }

    #[test]
    #[expected_failure(location = config,abort_code = events::ERR_UNSUPPORTED_COLLATERAL)]
    fun test_set_config_unsupported_collateral() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Try to update config for unregistered collateral (should fail)
        cdp_multi::set_config<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            true,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY
        );
    }

    #[test]
    fun test_set_config_disable_collateral() {
        let (_framework, admin) = setup_basic();
        timestamp::set_time_has_started_for_testing(&_framework);
        // Add TestCoin as collateral
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_RESERVE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            DECIMALS,
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY,
            1,
            900
        );
        
        // Verify collateral is initially enabled
        assert!(cdp_multi::is_valid_collateral<TestCoin>(), 0);
        
        // Disable the collateral
        cdp_multi::set_config<TestCoin>(
            &admin,
            DEFAULT_MIN_DEBT,
            DEFAULT_MCR,
            DEFAULT_BORROW_RATE,
            DEFAULT_LIQ_THRESHOLD,
            DEFAULT_LIQ_PENALTY,
            DEFAULT_REDEMPTION_FEE,
            false, // disabled
            DEFAULT_LIQ_FEE_PROTOCOL,
            DEFAULT_REDEMPTION_FEE_GRATUITY
        );
        
        // Verify collateral is now disabled
        assert!(!cdp_multi::is_valid_collateral<TestCoin>(), 1);
    }

    // #[test]
    // fun test_get_collateral_ratio() {
    //     let (_framework, admin) = setup_basic();
    //     timestamp::set_time_has_started_for_testing(&_framework);
        
    //     // Add TestCoin as collateral
    //     cdp_multi::add_collateral<TestCoin>(
    //         &admin,
    //         DEFAULT_MIN_DEBT,
    //         DEFAULT_MCR,
    //         DEFAULT_BORROW_RATE,
    //         DEFAULT_LIQ_RESERVE,
    //         DEFAULT_LIQ_THRESHOLD,
    //         DEFAULT_LIQ_PENALTY,
    //         DEFAULT_REDEMPTION_FEE,
    //         DECIMALS,
    //         DEFAULT_LIQ_FEE_PROTOCOL,
    //         DEFAULT_REDEMPTION_FEE_GRATUITY,
    //         1,
    //         900
    //     );

    //     // Test case 1: Exactly 150% ratio
    //     // With price = $10, 1000 TestCoin = $10,000 collateral value
    //     // Against 6,666.67 debt = 150% ratio
    //     let ratio1 = cdp_multi::get_collateral_ratio(
    //         1000 * SCALING_FACTOR,      // 1000 TestCoin
    //         6667 * SCALING_FACTOR,      // ~6,667 debt
    //         10 * SCALING_FACTOR         // $10 price
    //     );
    //     debug::print(&string::utf8(b"ratio1: "));
    //     debug::print(&ratio1);
    //     assert!(ratio1 >= 14990 && ratio1 <= 15010, 0); // Allow small rounding difference

    //     // Test case 2: Exactly 200% ratio
    //     // 1000 TestCoin at $10 = $10,000 collateral value
    //     // Against 5,000 debt = 200% ratio
    //     let ratio2 = cdp_multi::get_collateral_ratio(
    //         1000 * SCALING_FACTOR,      // 1000 TestCoin
    //         5000 * SCALING_FACTOR,      // 5000 debt
    //         10 * SCALING_FACTOR         // $10 price
    //     );
    //     assert!(ratio2 == 20000, 1);    // Should be exactly 200%

    //     // Test case 3: Zero debt (should return 0)
    //     let ratio3 = cdp_multi::get_collateral_ratio(
    //         1000 * SCALING_FACTOR,      // 1000 TestCoin
    //         0,                          // 0 debt
    //         10 * SCALING_FACTOR         // $10 price
    //     );
    //     assert!(ratio3 == 0, 2);        // Should return 0 for zero debt

    //     // Test case 4: Zero collateral with non-zero debt
    //     let ratio4 = cdp_multi::get_collateral_ratio(
    //         0,                          // 0 TestCoin
    //         1000 * SCALING_FACTOR,      // 1000 debt
    //         10 * SCALING_FACTOR         // $10 price
    //     );
    //     assert!(ratio4 == 0, 3);        // Should be 0% ratio

    //     // Test case 5: Large numbers (testing no overflow)
    //     let ratio5 = cdp_multi::get_collateral_ratio(
    //         1000000 * SCALING_FACTOR,   // 1M TestCoin
    //         5000000 * SCALING_FACTOR,   // 5M debt
    //         10 * SCALING_FACTOR         // $10 price
    //     );
    //     assert!(ratio5 == 20000, 4);    // Should still be 200%

    //     // Test case 6: Minimum viable amounts
    //     let ratio6 = cdp_multi::get_collateral_ratio(
    //         1 * SCALING_FACTOR,         // 1 TestCoin
    //         8 * SCALING_FACTOR,         // 8 debt (for ~125% ratio)
    //         10 * SCALING_FACTOR         // $10 price
    //     );
    //     assert!(ratio6 >= 12500 && ratio6 <= 12510, 5); // Allow small rounding difference
    // }

    // #[test]
    // fun test_get_collateral_ratio_with_price_changes() {
    //     let (_framework, admin) = setup_basic();
    //     timestamp::set_time_has_started_for_testing(&_framework);
        
    //     cdp_multi::add_collateral<TestCoin>(
    //         &admin,
    //         DEFAULT_MIN_DEBT,
    //         DEFAULT_MCR,
    //         DEFAULT_BORROW_RATE,
    //         DEFAULT_LIQ_RESERVE,
    //         DEFAULT_LIQ_THRESHOLD,
    //         DEFAULT_LIQ_PENALTY,
    //         DEFAULT_REDEMPTION_FEE,
    //         DECIMALS,
    //         DEFAULT_LIQ_FEE_PROTOCOL,
    //         DEFAULT_REDEMPTION_FEE_GRATUITY,
    //         1,
    //         900
    //     );

    //     let collateral = 1000 * SCALING_FACTOR;  // 1000 TestCoin
    //     let debt = 5000 * SCALING_FACTOR;        // 5000 debt

    //     // Test with different prices
    //     let ratio1 = cdp_multi::get_collateral_ratio(
    //         collateral,
    //         debt,
    //         10 * SCALING_FACTOR     // $10 price = 200% ratio
    //     );
        
    //     assert!(ratio1 == 20000, 0);

    //     let ratio2 = cdp_multi::get_collateral_ratio(
    //         collateral,
    //         debt,
    //         5 * SCALING_FACTOR      // $5 price = 100% ratio
    //     );
    //     assert!(ratio2 == 10000, 1);

    //     let ratio3 = cdp_multi::get_collateral_ratio(
    //         collateral,
    //         debt,
    //         20 * SCALING_FACTOR     // $20 price = 400% ratio
    //     );
    //     assert!(ratio3 == 40000, 2);
    // }


    // // Helper function to set price via mock Supra oracle
    // fun set_mock_price( price: u64,id :u32) {
    //     mock_oracle::set_price(
    //         id,                                    // pair_id: u32
    //         (price as u128),                      // price: u128
    //         8,                                    // decimals: u16
    //         (timestamp::now_seconds() as u64),    // timestamp: u64
    //         1                                     // round: u64
    //     );
    // }

    // // Helper function to update multiple collateral prices
    // fun update_mock_prices(admin: &signer) {
    //     set_mock_price<TestCoin>(admin, 10 * SCALING_FACTOR);     // $10
    //     set_mock_price<TestCoin2>(admin, 20 * SCALING_FACTOR);    // $20
    //     set_mock_price<SupraCoin>(admin, 50 * SCALING_FACTOR);    // $50
    // }
}