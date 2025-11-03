#[test_only]
module cdp::cdp_multi_edge_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::account;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use cdp::cdp_multi::{Self, CASH};
    use cdp::events;
    use supra_framework::block;
    use supra_framework::timestamp;
    use supra_framework::debug;

    struct TestCoin {}
    struct TestCoin2 {}

    const DECIMALS: u8 = 8;
    const SCALING_FACTOR: u64 = 100000000; // 10^8
    const FEE_COLLECTOR: address = @0x2db5c23e86ef48e8604685b14017a3c2625484ebf33d84d80c4541daf44c459a;
    // Helper function to setup test environment
    fun setup_test(): (signer, signer, signer) {
        let framework = account::create_account_for_test(@0x1);
        let admin = account::create_account_for_test(@cdp);
        let user = account::create_account_for_test(@0x123);
        timestamp::set_time_has_started_for_testing(&framework);
        cdp_multi::initialize(&admin,FEE_COLLECTOR);
        (framework, admin, user)
    }

    fun setup_collector_accounts() {
        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        coin::register<CASH>(&fee_collector);
        
        coin::register<SupraCoin>(&fee_collector);
    }

    fun setup_collector_accountsmulti() {
        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        
        // Register fee collector for CASH and test coins
        coin::register<CASH>(&fee_collector);
        coin::register<TestCoin>(&fee_collector);
        coin::register<TestCoin2>(&fee_collector);
        // coin::register<SupraCoin>(&fee_collector);
    }

    #[test]
    fun test_detailed_liquidation() {
        let (framework, admin, borrower) = setup_test();
        let liquidator = account::create_account_for_test(@0x456);

        // Initialize SUPRA
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
        setup_collector_accounts();
        block::initialize_for_test(&framework, 1); 

        // Setup collateral config with liquidation fee protocol of 1000 (10%)
        cdp_multi::add_collateral<SupraCoin>(
            &admin,
            25 * SCALING_FACTOR,  // min debt
            13000,               // MCR (130%)
            200,                // borrow rate (2%)
            2 * SCALING_FACTOR,  // liquidation reserve
            12000,              // liquidation threshold (120%)
            1000,               // liquidation penalty (10%)
            50,                 // redemption fee
            DECIMALS,
            1000,                // liquidation fee protocol (10%)
            100,               // redemption fee gratuity (1%)
            1,
            900
        );

        // Setup accounts
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        
        coin::register<SupraCoin>(&borrower);
        coin::register<CASH>(&borrower);
        coin::register<SupraCoin>(&liquidator);
        coin::register<CASH>(&liquidator);

        // Initial price $50
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

        // Give borrower initial SUPRA and open trove
        let collateral = 1000 * SCALING_FACTOR; // 1000 SUPRA
        let debt = 400 * SCALING_FACTOR;        // 400 ORE
        coin::deposit(borrower_addr, coin::mint(collateral, &mint_cap));

        // Open trove
        cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

        // Store initial balances
        let liquidator_initial_supra = coin::balance<SupraCoin>(liquidator_addr);
        let fee_collector_initial_supra = coin::balance<SupraCoin>(cdp_multi::get_fee_collector());

        // Drop price to make trove liquidatable (around 112% ratio)
        // cdp_multi::set_price<SupraCoin>(&admin, 45920000); // $0.4592
        cdp_multi::set_price<SupraCoin>(&admin, 41920000); // $0.4192

        // Get position before liquidation
        let (_, initial_debt, _) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
        
        cdp_multi::mint_debtToken_for_test(liquidator_addr, 2*initial_debt);
        cdp_multi::liquidate<SupraCoin>(&liquidator, borrower_addr);

        // Calculate penalty amount in collateral terms
        let price = cdp_multi::get_collateral_price_raw<SupraCoin>();
        let collateral_value = (collateral * price) / SCALING_FACTOR;
        let current_ratio = (collateral_value * 10000) / initial_debt;

        // Calculate penalty based on ICR
        let penalty_amount = if (current_ratio <= (10000 + 1000)) { // 1000 is liquidation_penalty
            // For 100% < ICR <= 100% + lp: penalty = (x*p) - y
            collateral_value - initial_debt
        } else {
            // For ICR > 100% + lp: penalty = lp*y
            (initial_debt * 1000) / 10000  // 1000 is liquidation_penalty
        };

        let penalty_amount_in_collateral = (penalty_amount * SCALING_FACTOR) / price;
        let protocol_fee = (penalty_amount_in_collateral * 1000) / 10000; // 1000 is liquidation_fee_protocol
        let liquidator_portion = penalty_amount_in_collateral - protocol_fee;

        // Add debt conversion to collateral
        let debt_in_collateral = (initial_debt * SCALING_FACTOR) / price;
        let expected_liquidator_reward = liquidator_portion + debt_in_collateral;

        // Verify liquidator's reward
        let liquidator_final_supra = coin::balance<SupraCoin>(liquidator_addr);
        let actual_liquidator_reward = liquidator_final_supra - liquidator_initial_supra;

        let expected_user_refund=if(expected_liquidator_reward + protocol_fee < collateral){
            collateral-(expected_liquidator_reward + protocol_fee)
        }  else{
            0
        };
        
        // Allow 0.01% difference
        let difference = if (actual_liquidator_reward > expected_liquidator_reward) {
            actual_liquidator_reward - expected_liquidator_reward
        } else {
            expected_liquidator_reward - actual_liquidator_reward
        };
        debug::print(&string::utf8(b"expected_user_refund+expected_liquidator_reward+protocol_fee: "));
        debug::print(&(expected_user_refund+expected_liquidator_reward+protocol_fee));
        debug::print(&string::utf8(b"actual_liquidator_reward: "));
        debug::print(&actual_liquidator_reward);
        debug::print(&string::utf8(b"expected_liquidator_reward: "));
        debug::print(&expected_liquidator_reward);
        debug::print(&string::utf8(b"difference: "));
        debug::print(&difference);
        debug::print(&string::utf8(b"allowed_difference: "));
        debug::print(&(expected_liquidator_reward / 10000));
        assert!(difference <= expected_liquidator_reward / 10000, 3);

        // Verify protocol fee
        let fee_collector_final_supra = coin::balance<SupraCoin>(cdp_multi::get_fee_collector());
        let actual_protocol_fee = fee_collector_final_supra - fee_collector_initial_supra;
        
        let fee_difference = if (actual_protocol_fee > protocol_fee) {
            actual_protocol_fee - protocol_fee
        } else {
            protocol_fee - actual_protocol_fee
        };
        // assert!(fee_difference <= expected_protocol_fee / 10000, 4);

        // Verify user refund
        let user_final_supra = coin::balance<SupraCoin>(borrower_addr);
        let refund_difference = if (user_final_supra > expected_user_refund) {
            user_final_supra - expected_user_refund
        } else {
            expected_user_refund - user_final_supra
        };
        // assert!(refund_difference <= expected_user_refund / 10000, 5);

        // Verify total collateral distribution doesn't exceed original amount
        let total_distributed = actual_liquidator_reward + actual_protocol_fee + user_final_supra;
        assert!(total_distributed <= collateral, 6);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_CANNOT_LIQUIDATE)]
    fun test_cannot_liquidate_healthy_position() {
        let (framework, admin, borrower) = setup_test();
        let borrower_addr = signer::address_of(&borrower);
        let liquidator = account::create_account_for_test(@0x456);
        let liquidator_addr = signer::address_of(&liquidator);
        block::initialize_for_test(&framework, 1); 
        // Initialize SUPRA coin
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        setup_collector_accounts();

        // Setup CDP with standard parameters and liquidation fee protocol
        cdp_multi::add_collateral<SupraCoin>(
            &admin,
            25 * SCALING_FACTOR,  // min debt
            13000,               // MCR (130%)
            200,                // borrow rate (2%)
            2 * SCALING_FACTOR,  // liquidation reserve
            12000,              // liquidation threshold (120%)
            1000,               // liquidation penalty (10%)
            50,                 // redemption fee (0.5%)
            DECIMALS,
            1000,                // liquidation fee protocol (10%)
            100,                // redemption fee gratuity (1%)
            1,
            900
        );

        // Set initial SUPRA price to $50
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

        // Register accounts for coins
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&borrower);
        coin::register<SupraCoin>(&liquidator);
        coin::register<CASH>(&borrower);
        coin::register<CASH>(&liquidator);

        // Give borrower initial SUPRA
        let initial_supra = 1000 * SCALING_FACTOR;
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(borrower_addr, coins);

        // Open trove with healthy position
        // 200 SUPRA ($10,000) collateral, 5000 debtToken debt = 200% collateral ratio
        let collateral = 200 * SCALING_FACTOR;
        let borrow_amount = 5000 * SCALING_FACTOR;
        cdp_multi::open_trove<SupraCoin>(&borrower, collateral, borrow_amount);

        // Give liquidator enough debtToken to attempt liquidation
        cdp_multi::mint_debtToken_for_test(liquidator_addr, borrow_amount);

        // Try to liquidate healthy position - should fail
        cdp_multi::liquidate<SupraCoin>(&liquidator, borrower_addr);
        assert!(false, 1);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

        #[test]
    #[expected_failure(location = cdp_multi, abort_code = events::ERR_SELF_LIQUIDATION)]
    fun test_cannot_self_liquidate() {
        let (framework, admin, borrower) = setup_test();
        let borrower_addr = signer::address_of(&borrower);
        block::initialize_for_test(&framework, 1); 

        // Initialize SUPRA coin
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        setup_collector_accounts();

        // Setup CDP with standard parameters
        cdp_multi::add_collateral<SupraCoin>(
            &admin,
            25 * SCALING_FACTOR,  // min debt
            13000,               // MCR (130%)
            200,                // borrow rate (2%)
            2 * SCALING_FACTOR,  // liquidation reserve
            12000,              // liquidation threshold (120%)
            1000,               // liquidation penalty (10%)
            50,                 // redemption fee
            DECIMALS,
            1000,                // liquidation fee protocol (10%)
            100,                // redemption fee gratuity (1%)
            1,
            900
        );

        // Set initial SUPRA price to $50
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

        // Register accounts for coins
        coin::register<SupraCoin>(&borrower);
        coin::register<CASH>(&borrower);

        // Give borrower initial SUPRA
        let initial_supra = 1000 * SCALING_FACTOR;
        coin::deposit(borrower_addr, coin::mint(initial_supra, &mint_cap));

        // Open trove with position that would be liquidatable
        let collateral = 200 * SCALING_FACTOR;
        let borrow_amount = 5000 * SCALING_FACTOR;
        cdp_multi::open_trove<SupraCoin>(&borrower, collateral, borrow_amount);

        // Drop price to make position liquidatable
        cdp_multi::set_price<SupraCoin>(&admin, 41920000); // $0.4192

        // Give borrower enough debtToken to attempt self-liquidation
        cdp_multi::mint_debtToken_for_test(borrower_addr, borrow_amount);

        // Try to self-liquidate - should fail
        cdp_multi::liquidate<SupraCoin>(&borrower, borrower_addr);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_liquidate_multiple_collateral_types() {
        let (framework, admin, borrower) = setup_test();
        let liquidator = account::create_account_for_test(@0x456);
        let dummyBorrower = account::create_account_for_test(@0x567);
        block::initialize_for_test(&framework, 1); 
        // Initialize test coins and setup collector accounts
        let (burn_cap1, freeze_cap1, mint_cap1) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );

        let (burn_cap2, freeze_cap2, mint_cap2) = coin::initialize<TestCoin2>(
            &admin,
            string::utf8(b"Test Coin 2"),
            string::utf8(b"TEST2"),
            DECIMALS,
            true
        );
        setup_collector_accountsmulti();

        // Setup collateral configurations
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            20 * SCALING_FACTOR,  // min debt
            12500,               // MCR (125%)
            200,                // borrow rate
            2 * SCALING_FACTOR,  // liquidation reserve
            11500,              // liquidation threshold
            1000,               // liquidation penalty
            50,                 // redemption fee
            DECIMALS,
            1000,                // liquidation fee protocol (10%)
            100,                // redemption fee gratuity (1%)
            1,
            900
        );

        cdp_multi::add_collateral<TestCoin2>(
            &admin,
            40 * SCALING_FACTOR,  // min debt
            13000,               // MCR (130%)
            200,                // borrow rate
            2 * SCALING_FACTOR,  // liquidation reserve
            12000,              // liquidation threshold
            1000,               // liquidation penalty
            50,                 // redemption fee
            DECIMALS,
            1000,                // liquidation fee protocol (10%)
            100,                // redemption fee gratuity (1%)
            1,
            900
        );

        // Setup accounts
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        let dummyBorrower_addr = signer::address_of(&dummyBorrower);
        
        coin::register<TestCoin>(&borrower);
        coin::register<TestCoin2>(&borrower);
        coin::register<CASH>(&borrower);
        coin::register<TestCoin>(&dummyBorrower);
        coin::register<TestCoin2>(&dummyBorrower);
        coin::register<CASH>(&dummyBorrower);
        coin::register<TestCoin>(&liquidator);
        coin::register<TestCoin2>(&liquidator);
        coin::register<CASH>(&liquidator);

        // Set initial prices
        cdp_multi::set_price<TestCoin>(&admin, 50 * SCALING_FACTOR);  // $10
        cdp_multi::set_price<TestCoin2>(&admin, 50 * SCALING_FACTOR); // $20



        // Give borrower initial collateral
        let collateral1 = 1000 * SCALING_FACTOR; // 1000 TEST1 = $10,000
        let collateral2 = 1000 * SCALING_FACTOR;  // 500 TEST2 = $10,000
        coin::deposit(borrower_addr, coin::mint(collateral1, &mint_cap1));
        coin::deposit(borrower_addr, coin::mint(collateral2, &mint_cap2));
        coin::deposit(dummyBorrower_addr, coin::mint(collateral1, &mint_cap1));
        coin::deposit(dummyBorrower_addr, coin::mint(collateral2, &mint_cap2));
        // Store initial balances
        let liquidator_initial_test1 = coin::balance<TestCoin>(liquidator_addr);
        let liquidator_initial_test2 = coin::balance<TestCoin2>(liquidator_addr);
        let fee_collector_initial_test1 = coin::balance<TestCoin>(cdp_multi::get_fee_collector());
        let fee_collector_initial_test2 = coin::balance<TestCoin2>(cdp_multi::get_fee_collector());

        // Open troves with reasonable debt amounts
        let debt1 = 400 * SCALING_FACTOR; // $5000 debt against $10,000 collateral (200% CR)
        let debt2 = 400 * SCALING_FACTOR; // $4000 debt against $10,000 collateral (250% CR)
        cdp_multi::open_trove<TestCoin>(&borrower, collateral1, debt1);
        cdp_multi::open_trove<TestCoin2>(&borrower, collateral2, debt2);
        // cdp_multi::open_trove<TestCoin>(&dummyBorrower, collateral1, debt1);
        // cdp_multi::open_trove<TestCoin2>(&dummyBorrower, collateral2, debt2);
        // Drop prices to make positions liquidatable but keep CR > 100%
        // For TestCoin: Need CR between 100% and 115%
        // Target ~110% CR: (price * 1000) / 5000 = 1.10
        // price = 5.5
        cdp_multi::set_price<TestCoin>(&admin,45920000);  // $5.50 -> CR = 110%
        // For TestCoin2: Need CR between 100% and 120%
        // Target ~110% CR: (price * 500) / 4000 = 1.10
        // price = 8.8
        cdp_multi::set_price<TestCoin2>(&admin, 45920000); // $8.80 -> CR = 110%

      

        let (_, initial_debt1, _) = cdp_multi::get_user_position<TestCoin>(borrower_addr);
        let (_, initial_debt2, _) = cdp_multi::get_user_position<TestCoin2>(borrower_addr);

        // Calculate required debtToken for liquidation (total debt - liquidation reserve)
        let liquidation_reserve = 2 * SCALING_FACTOR;
        let required_debtToken1 = initial_debt1 - liquidation_reserve;
        let required_debtToken2 = initial_debt2 - liquidation_reserve;
        // Mint slightly more than required to account for rounding
        let total_required_debtToken = required_debtToken1 + required_debtToken2 + (4 * SCALING_FACTOR);
        cdp_multi::mint_debtToken_for_test(liquidator_addr, total_required_debtToken);

        // Liquidate both positions
        cdp_multi::liquidate<TestCoin>(&liquidator, borrower_addr);
        cdp_multi::liquidate<TestCoin2>(&liquidator, borrower_addr);

        // Verify positions are closed
        let (coll1, debt1, active1) = cdp_multi::get_user_position<TestCoin>(borrower_addr);
        let (coll2, debt2, active2) = cdp_multi::get_user_position<TestCoin2>(borrower_addr);
        assert!(coll1 == 0 && debt1 == 0 && !active1, 0);
        assert!(coll2 == 0 && debt2 == 0 && !active2, 1);

        // Clean up
        coin::destroy_burn_cap<TestCoin>(burn_cap1);
        coin::destroy_burn_cap<TestCoin2>(burn_cap2);
        coin::destroy_freeze_cap<TestCoin>(freeze_cap1);
        coin::destroy_freeze_cap<TestCoin2>(freeze_cap2);
        coin::destroy_mint_cap<TestCoin>(mint_cap1);
        coin::destroy_mint_cap<TestCoin2>(mint_cap2);
    }

    #[test]
    fun test_liquidate_undercollateralized() {
        let (framework, admin, borrower) = setup_test();
        let liquidator = account::create_account_for_test(@0x456);

        // Initialize SUPRA
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
        setup_collector_accounts();
        block::initialize_for_test(&framework, 1); 

        // Setup collateral config
        cdp_multi::add_collateral<SupraCoin>(
            &admin,
            25 * SCALING_FACTOR,  // min debt
            13000,               // MCR (130%)
            200,                // borrow rate (2%)
            2 * SCALING_FACTOR,  // liquidation reserve
            12000,              // liquidation threshold (120%)
            1000,               // liquidation penalty (10%)
            50,                 // redemption fee
            DECIMALS,
            1000,                // liquidation fee protocol (10%)
            100,               // redemption fee gratuity (1%)
            1,
            900
        );

        // Setup accounts
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        
        coin::register<SupraCoin>(&borrower);
        coin::register<CASH>(&borrower);
        coin::register<SupraCoin>(&liquidator);
        coin::register<CASH>(&liquidator);

        // Initial price $50
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

        // Open trove with 100 SUPRA ($5000) and 3000 debtToken debt
        // Initial CR = (100 * $50) / 3000 = 166.67%
        let collateral = 100 * SCALING_FACTOR;
        let debt = 3000 * SCALING_FACTOR;
        coin::deposit(borrower_addr, coin::mint(collateral, &mint_cap));
        cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

        // // Store initial balances
        let liquidator_initial_supra = coin::balance<SupraCoin>(liquidator_addr);

        // Drop price to make position undercollateralized (ICR < 100%)
        // New price $25 -> CR = (100 * $25) / 3000 = 83.33%
        cdp_multi::set_price<SupraCoin>(&admin, 25 * SCALING_FACTOR);
        cdp_multi::mint_debtToken_for_test(liquidator_addr, 2*debt);

        // Execute liquidation
        cdp_multi::liquidate<SupraCoin>(&liquidator, borrower_addr);

        // Verify liquidator received all collateral
        let liquidator_final_supra = coin::balance<SupraCoin>(liquidator_addr);
        let liquidator_supra_gain = liquidator_final_supra - liquidator_initial_supra;
        assert!(liquidator_supra_gain == collateral, 1); // Liquidator should receive all collateral

        // Verify position is closed
        let (coll, debt_amount, active) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
        assert!(coll == 0 && debt_amount == 0 && !active, 2);

        // Verify borrower has no remaining SUPRA
        let borrower_final_supra = coin::balance<SupraCoin>(borrower_addr);
        assert!(borrower_final_supra == 0, 3);

        // Verify fee collector received nothing (no protocol fee when ICR <= 100%)
        let fee_collector_supra = coin::balance<SupraCoin>(cdp_multi::get_fee_collector());
        assert!(fee_collector_supra == 0, 4);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_partial_liquidation_final_portion() {
        let (framework, admin, borrower) = setup_test();
        let liquidator = account::create_account_for_test(@0x456);

        // Initialize SUPRA
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
        setup_collector_accounts();
        block::initialize_for_test(&framework, 1); 

        // Setup collateral config
        cdp_multi::add_collateral<SupraCoin>(
            &admin,
            25 * SCALING_FACTOR,  // min debt
            13000,               // MCR (130%)
            200,                // borrow rate (2%)
            2 * SCALING_FACTOR,  // liquidation reserve
            12000,              // liquidation threshold (120%)
            1000,               // liquidation penalty (10%)
            50,                 // redemption fee
            DECIMALS,
            1000,               // liquidation fee protocol (10%)
            100,                // redemption fee gratuity (1%)
            1,
            900
        );

        // Setup accounts
        let borrower_addr = signer::address_of(&borrower);
        let liquidator_addr = signer::address_of(&liquidator);
        
        coin::register<SupraCoin>(&borrower);
        coin::register<CASH>(&borrower);
        coin::register<SupraCoin>(&liquidator);
        coin::register<CASH>(&liquidator);

        // Initial price $50
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

        // Open trove with 1000 SUPRA and 30,000 debtToken debt
        let collateral = 1000 * SCALING_FACTOR;
        let debt = 30000 * SCALING_FACTOR;
        coin::deposit(borrower_addr, coin::mint<SupraCoin>(collateral, &mint_cap));
        cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

        // Make position liquidatable
        cdp_multi::set_price<SupraCoin>(&admin, 35 * SCALING_FACTOR);

        // Store initial balances
        let liquidator_initial_supra = coin::balance<SupraCoin>(liquidator_addr);
        
        let (original_coll, original_debt, active) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
        // Attempt to liquidate entire debt
        cdp_multi::mint_debtToken_for_test(liquidator_addr, original_debt);
        cdp_multi::partial_liquidate<SupraCoin>(&liquidator, borrower_addr, original_debt);

        // Verify position is closed
        let (remaining_coll, remaining_debt, active) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
        assert!(!active, 1);
        assert!(remaining_debt == 0, 2);
        assert!(remaining_coll == 0, 3);

        // Verify liquidator received liquidation reserve
        let liquidator_debtToken_balance = coin::balance<CASH>(liquidator_addr);
        assert!(liquidator_debtToken_balance == 2 * SCALING_FACTOR, 4); // Should have liquidation reserve

        coin::destroy_burn_cap<SupraCoin>(burn_cap);
        coin::destroy_mint_cap<SupraCoin>(mint_cap);
    }

    // #[test]
    // fun test_partial_liquidation_underwater() {
    //     let (framework, admin, borrower) = setup_test();
    //     let liquidator = account::create_account_for_test(@0x456);

    //     // Initialize SUPRA
    //     let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
    //     setup_collector_accounts();
    //     block::initialize_for_test(&framework, 1); 

    //     // Setup collateral config
    //     cdp_multi::add_collateral<SupraCoin>(
    //         &admin,
    //         25 * SCALING_FACTOR,  // min debt
    //         13000,               // MCR (130%)
    //         200,                // borrow rate (2%)
    //         2 * SCALING_FACTOR,  // liquidation reserve
    //         12000,              // liquidation threshold (120%)
    //         1000,               // liquidation penalty (10%)
    //         50,                 // redemption fee
    //         DECIMALS,
    //         1000,               // liquidation fee protocol (10%)
    //         100,                // redemption fee gratuity (1%)
    //         1,
    //         900
    //     );

    //     // Setup accounts
    //     let borrower_addr = signer::address_of(&borrower);
    //     let liquidator_addr = signer::address_of(&liquidator);
        
    //     coin::register<SupraCoin>(&borrower);
    //     coin::register<CASH>(&borrower);
    //     coin::register<SupraCoin>(&liquidator);
    //     coin::register<CASH>(&liquidator);

    //     // Initial price $50
    //     cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

    //     // Open trove with 1000 SUPRA and 30,000 debtToken debt
    //     let collateral = 1000 * SCALING_FACTOR;
    //     let debt = 30000 * SCALING_FACTOR;
    //     coin::deposit(borrower_addr, coin::mint<SupraCoin>(collateral, &mint_cap));
    //     cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

    //     // Drop price to make position underwater (<100% CR)
    //     cdp_multi::set_price<SupraCoin>(&admin, 25 * SCALING_FACTOR);

    //     // Try to partially liquidate 1/3 of the position
    //     let (original_coll, original_debt, active) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
    //     let partial_debt = debt / 3;
        
    //     // Calculate expected collateral to be liquidated using ceiling division
    //     let collateral_amount_u128 = (original_coll as u128);
    //     let debt_to_liquidate_u128 = (partial_debt as u128);
    //     let debt_amount_u128 = (original_debt as u128);
        
    //     let numerator = collateral_amount_u128 * debt_to_liquidate_u128;
    //     let collateral_to_liquidate = if (numerator % debt_amount_u128 == 0) {
    //         // If division is exact, use the exact result
    //         ((numerator / debt_amount_u128) as u64)
    //     } else {
    //         // If there's a remainder, round up (ceiling division)
    //         ((numerator / debt_amount_u128 + 1) as u64)
    //     };
        
    //     // Safety cap - don't exceed available collateral
    //     if (collateral_to_liquidate > original_coll) {
    //         collateral_to_liquidate = original_coll;
    //     };
        
    //     let expected_remaining_coll = original_coll - collateral_to_liquidate;
        
    //     cdp_multi::mint_debtToken_for_test(liquidator_addr, partial_debt);
    //     cdp_multi::partial_liquidate<SupraCoin>(&liquidator, borrower_addr, partial_debt);

    //     // Verify remaining position
    //     let (remaining_coll, remaining_debt, active) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
    //     assert!(active, 1);
    //     assert!(remaining_debt == original_debt - partial_debt, 2);
        
    //     // Debug outputs to understand the values
    //     debug::print(&string::utf8(b"Original collateral:"));
    //     debug::print(&original_coll);
    //     debug::print(&string::utf8(b"Collateral to liquidate (ceiling division):"));
    //     debug::print(&collateral_to_liquidate);
    //     debug::print(&string::utf8(b"Expected remaining collateral:"));
    //     debug::print(&expected_remaining_coll);
    //     debug::print(&string::utf8(b"Actual remaining collateral:"));
    //     debug::print(&remaining_coll);
        
    //     // The remaining collateral should match our expected calculation using ceiling division
    //     assert!(remaining_coll == expected_remaining_coll, 3);

    //     coin::destroy_burn_cap<SupraCoin>(burn_cap);
    //     coin::destroy_mint_cap<SupraCoin>(mint_cap);
    // }

    // #[test]
    // #[expected_failure(abort_code = events::ERR_INVALID_DEBT_AMOUNT)]
    // fun test_partial_liquidation_zero_debt() {
    //     let (framework, admin, borrower) = setup_test();
    //     let liquidator = account::create_account_for_test(@0x456);

    //     // Initialize SUPRA
    //     let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
    //     setup_collector_accounts();
    //     block::initialize_for_test(&framework, 1); 

    //     // Setup collateral config
    //     cdp_multi::add_collateral<SupraCoin>(
    //         &admin,
    //         25 * SCALING_FACTOR,  // min debt
    //         13000,               // MCR (130%)
    //         200,                // borrow rate (2%)
    //         2 * SCALING_FACTOR,  // liquidation reserve
    //         12000,              // liquidation threshold (120%)
    //         1000,               // liquidation penalty (10%)
    //         50,                 // redemption fee
    //         DECIMALS,
    //         1000,               // liquidation fee protocol (10%)
    //         100,                // redemption fee gratuity (1%)
    //         1,
    //         900
    //     );

    //     // Setup accounts
    //     let borrower_addr = signer::address_of(&borrower);
    //     let liquidator_addr = signer::address_of(&liquidator);
        
    //     coin::register<SupraCoin>(&borrower);
    //     coin::register<CASH>(&borrower);
    //     coin::register<SupraCoin>(&liquidator);
    //     coin::register<CASH>(&liquidator);

    //     // Initial price $50
    //     cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

    //     // Open trove with 1000 SUPRA and 30,000 debtToken debt
    //     let collateral = 1000 * SCALING_FACTOR;
    //     let debt = 30000 * SCALING_FACTOR;
    //     coin::deposit(borrower_addr, coin::mint<SupraCoin>(collateral, &mint_cap));
    //     cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

    //     // Make position liquidatable
    //     cdp_multi::set_price<SupraCoin>(&admin, 35 * SCALING_FACTOR);
        
    //     // Try to liquidate zero debt
    //     cdp_multi::partial_liquidate<SupraCoin>(&liquidator, borrower_addr, 0);

    //     coin::destroy_burn_cap<SupraCoin>(burn_cap);
    //     coin::destroy_mint_cap<SupraCoin>(mint_cap);
    // }

    // #[test]
    // #[expected_failure(abort_code = events::ERR_INVALID_DEBT_AMOUNT)]
    // fun test_partial_liquidation_excess_debt() {
    //     let (framework, admin, borrower) = setup_test();
    //     let liquidator = account::create_account_for_test(@0x456);

    //     // Initialize SUPRA
    //     let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
    //     setup_collector_accounts();
    //     block::initialize_for_test(&framework, 1); 

    //     // Setup collateral config
    //     cdp_multi::add_collateral<SupraCoin>(
    //         &admin,
    //         25 * SCALING_FACTOR,  // min debt
    //         13000,               // MCR (130%)
    //         200,                // borrow rate (2%)
    //         2 * SCALING_FACTOR,  // liquidation reserve
    //         12000,              // liquidation threshold (120%)
    //         1000,               // liquidation penalty (10%)
    //         50,                 // redemption fee
    //         DECIMALS,
    //         1000,               // liquidation fee protocol (10%)
    //         100,                // redemption fee gratuity (1%)
    //         1,
    //         900
    //     );

    //     // Setup accounts
    //     let borrower_addr = signer::address_of(&borrower);
    //     let liquidator_addr = signer::address_of(&liquidator);
        
    //     coin::register<SupraCoin>(&borrower);
    //     coin::register<CASH>(&borrower);
    //     coin::register<SupraCoin>(&liquidator);
    //     coin::register<CASH>(&liquidator);

    //     // Initial price $50
    //     cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

    //     // Open trove with 30,000 debtToken debt
    //     let collateral = 1000 * SCALING_FACTOR;
    //     let debt = 30000 * SCALING_FACTOR;
    //     coin::deposit(borrower_addr, coin::mint<SupraCoin>(collateral, &mint_cap));
    //     cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

    //     // Make position liquidatable
    //     cdp_multi::set_price<SupraCoin>(&admin, 35 * SCALING_FACTOR);

    //     // Try to liquidate more than total debt
    //     cdp_multi::partial_liquidate<SupraCoin>(&liquidator, borrower_addr, debt + SCALING_FACTOR);

    //     coin::destroy_burn_cap<SupraCoin>(burn_cap);
    //     coin::destroy_mint_cap<SupraCoin>(mint_cap);
    // }

    // #[test]
    // #[expected_failure(abort_code = events::ERR_SELF_LIQUIDATION)]
    // fun test_partial_liquidation_self_liquidate() {
    //     let (framework, admin, borrower) = setup_test();
        
    //     // Initialize SUPRA
    //     let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
    //     setup_collector_accounts();
    //     block::initialize_for_test(&framework, 1); 

    //     // Setup collateral config
    //     cdp_multi::add_collateral<SupraCoin>(
    //         &admin,
    //         25 * SCALING_FACTOR,  // min debt
    //         13000,               // MCR (130%)
    //         200,                // borrow rate (2%)
    //         2 * SCALING_FACTOR,  // liquidation reserve
    //         12000,              // liquidation threshold (120%)
    //         1000,               // liquidation penalty (10%)
    //         50,                 // redemption fee
    //         DECIMALS,
    //         1000,               // liquidation fee protocol (10%)
    //         100,                // redemption fee gratuity (1%)
    //         1,
    //         900
    //     );

    //     // Setup accounts
    //     let borrower_addr = signer::address_of(&borrower);
        
    //     coin::register<SupraCoin>(&borrower);
    //     coin::register<CASH>(&borrower);

    //     // Initial price $50
    //     cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

    //     // Open trove with 30,000 debtToken debt
    //     let collateral = 1000 * SCALING_FACTOR;
    //     let debt = 30000 * SCALING_FACTOR;
    //     coin::deposit(borrower_addr, coin::mint<SupraCoin>(collateral, &mint_cap));
    //     cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

    //     // Make position liquidatable
    //     cdp_multi::set_price<SupraCoin>(&admin, 35 * SCALING_FACTOR);
        
    //     // Try to self-liquidate
    //     cdp_multi::partial_liquidate<SupraCoin>(&borrower, borrower_addr, debt / 2);

    //     coin::destroy_burn_cap<SupraCoin>(burn_cap);
    //     coin::destroy_mint_cap<SupraCoin>(mint_cap);
    // }

    // #[test]
    // fun test_partial_liquidation_multiple_rounds() {
    //     let (framework, admin, borrower) = setup_test();
    //     let liquidator1 = account::create_account_for_test(@0x456);
    //     let liquidator2 = account::create_account_for_test(@0x789);

    //     // Initialize SUPRA
    //     let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
    //     setup_collector_accounts();
    //     block::initialize_for_test(&framework, 1); 

    //     // Setup collateral config
    //     cdp_multi::add_collateral<SupraCoin>(
    //         &admin,
    //         25 * SCALING_FACTOR,  // min debt
    //         13000,               // MCR (130%)
    //         200,                // borrow rate (2%)
    //         2 * SCALING_FACTOR,  // liquidation reserve
    //         12000,              // liquidation threshold (120%)
    //         1000,               // liquidation penalty (10%)
    //         50,                 // redemption fee
    //         DECIMALS,
    //         1000,               // liquidation fee protocol (10%)
    //         100,                // redemption fee gratuity (1%)
    //         1,
    //         900
    //     );

    //     // Setup accounts
    //     let borrower_addr = signer::address_of(&borrower);
    //     let liquidator1_addr = signer::address_of(&liquidator1);
    //     let liquidator2_addr = signer::address_of(&liquidator2);
        
    //     coin::register<SupraCoin>(&borrower);
    //     coin::register<CASH>(&borrower);
    //     coin::register<SupraCoin>(&liquidator1);
    //     coin::register<CASH>(&liquidator1);
    //     coin::register<SupraCoin>(&liquidator2);
    //     coin::register<CASH>(&liquidator2);

    //     // Initial price $50
    //     cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);

    //     // Setup position with 1000 SUPRA and 30,000 debtToken debt
    //     let collateral = 1000 * SCALING_FACTOR;
    //     let debt = 30000 * SCALING_FACTOR;
    //     coin::deposit(borrower_addr, coin::mint<SupraCoin>(collateral, &mint_cap));
    //     cdp_multi::open_trove<SupraCoin>(&borrower, collateral, debt);

    //     // Make position liquidatable
    //     cdp_multi::set_price<SupraCoin>(&admin, 35 * SCALING_FACTOR);

    //     // First liquidator takes 1/3
    //     let partial_debt = debt / 3;
    //     cdp_multi::mint_debtToken_for_test(liquidator1_addr, partial_debt);
    //     cdp_multi::partial_liquidate<SupraCoin>(&liquidator1, borrower_addr, partial_debt);

    //     // Second liquidator takes another 1/3
    //     cdp_multi::mint_debtToken_for_test(liquidator2_addr, partial_debt);
    //     cdp_multi::partial_liquidate<SupraCoin>(&liquidator2, borrower_addr, partial_debt);

    //     // First liquidator takes final portion
    //     let final_debt = debt - (2 * partial_debt);
    //     cdp_multi::mint_debtToken_for_test(liquidator1_addr, final_debt);
    //     cdp_multi::partial_liquidate<SupraCoin>(&liquidator1, borrower_addr, final_debt);

    //     // Verify position is closed
    //     let (_, _, active) = cdp_multi::get_user_position<SupraCoin>(borrower_addr);
    //     assert!(!active, 1);

    //     // Verify only final liquidator got liquidation reserve
    //     let liquidator1_debtToken = coin::balance<CASH>(liquidator1_addr);
    //     let liquidator2_debtToken = coin::balance<CASH>(liquidator2_addr);
    //     assert!(liquidator1_debtToken == 2 * SCALING_FACTOR, 2); // Should have liquidation reserve
    //     assert!(liquidator2_debtToken == 0, 3); // Should not have liquidation reserve

    //     coin::destroy_burn_cap<SupraCoin>(burn_cap);
    //     coin::destroy_mint_cap<SupraCoin>(mint_cap);
    // }

}