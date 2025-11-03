#[test_only]
module cdp::cdp_multi_trove_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::account;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use cdp::cdp_multi::{Self, CASH};
    use supra_framework::timestamp;
    use cdp::events;
    use supra_framework::block;
    use cdp::positions;

    // Test coins for multi-collateral testing
    struct TestCoin {}
    // Test coins for multi-collateral testing
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
        // // Initialize SupraCoin
        // let (burn_cap, mint_cap) = supra_coin::initialize_for_test(&framework);
        // coin::destroy_burn_cap(burn_cap);
        // coin::destroy_mint_cap(mint_cap);

        // Initialize CDP system
        cdp_multi::initialize(&admin,FEE_COLLECTOR);

        (framework, admin, user)
    }

    fun setup_collector_accounts() {
        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        
        // Register fee collector for CASH and test coins
        coin::register<CASH>(&fee_collector);
        coin::register<TestCoin>(&fee_collector);
        coin::register<TestCoin2>(&fee_collector);
        // coin::register<SupraCoin>(&fee_collector);
    }

    #[test]
    fun test_open_trove_with_supra() {
        let (framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        // timestamp::set_time_has_started_for_testing(&framework);

        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
        block::initialize_for_test(&framework, 1); 
        // Setup multi-collateral system
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
            100,
            100,1,
            900
        );

        // Set SUPRA price to $50
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR);
        coin::register<SupraCoin>(&admin); // Register admin (CDP contract) for SupraCoin
        coin::register<SupraCoin>(&user);
        coin::register<CASH>(&fee_collector);
        coin::register<SupraCoin>(&fee_collector);

        // // Register user for coins
        // coin::register<SupraCoin>(&user);
        coin::register<CASH>(&user);
        let initial_supra = 1000 * SCALING_FACTOR;
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);

        // // Open trove
        let collateral = 200 * SCALING_FACTOR; // 200 SUPRA ($10,000 worth)
        let borrow_amount = 5000 * SCALING_FACTOR; // 5000 debtToken (50% collateral ratio)
        cdp_multi::open_trove<SupraCoin>(&user, collateral, borrow_amount);

        // // Verify trove state
        // let (actual_debt, actual_collateral, is_active) = cdp_multi::get_user_position<SupraCoin>(user_addr);
        
        // // Calculate expected debt (including fees)
        // let borrow_fee = (borrow_amount * 200) / 10000; // 2% fee
        // let liquidation_reserve = 2 * SCALING_FACTOR;
        // let expected_debt = borrow_amount + borrow_fee + liquidation_reserve;

        // assert!(actual_collateral == collateral, 0);
        // assert!(actual_debt == expected_debt, 1);
        // assert!(is_active == true, 2);

        // // Verify user balances
        // assert!(coin::balance<SupraCoin>(user_addr) == initial_supra - collateral, 3);
        // assert!(coin::balance<CASH>(user_addr) == borrow_amount, 4);
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_open_trove_with_multiple_collaterals() {
        let (framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        block::initialize_for_test(&framework, 1); 

        // Initialize timestamp using framework account
        // timestamp::set_time_has_started_for_testing(&framework);

        // Initialize test coins
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
        setup_collector_accounts();


        // Register user for coins
        coin::register<TestCoin>(&user);
        coin::register<TestCoin2>(&user);
        coin::register<CASH>(&user);

        // Mint and deposit in one step to avoid unused coins
        coin::deposit(user_addr, coin::mint<TestCoin>(500 * SCALING_FACTOR, &mint_cap1));
        coin::deposit(user_addr, coin::mint<TestCoin2>(250 * SCALING_FACTOR, &mint_cap2));

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
            100,
            100,1,
            900
        );

        cdp_multi::add_collateral<TestCoin2>(
            &admin,
            40 * SCALING_FACTOR,  // higher min debt
            13000,               // higher MCR (130%)
            200,                // same borrow rate
            2 * SCALING_FACTOR,  // same liquidation reserve
            12000,              // higher liquidation threshold
            1000,               // same liquidation penalty
            50,                 // same redemption fee
            DECIMALS,
            100,
            100,1,
            900
        );

        // Set prices
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);  // $10
        cdp_multi::set_price<TestCoin2>(&admin, 20 * SCALING_FACTOR); // $20

        // Register user for all coins
        coin::register<TestCoin>(&user);
        coin::register<TestCoin2>(&user);
        coin::register<CASH>(&user);

        // Open troves
        cdp_multi::open_trove<TestCoin>(&user, 100 * SCALING_FACTOR, 500 * SCALING_FACTOR);
        cdp_multi::open_trove<TestCoin2>(&user, 50 * SCALING_FACTOR, 400 * SCALING_FACTOR);
        // Verify positions
        let (coll1,_debt1,  is_active1) = cdp_multi::get_user_position<TestCoin>(user_addr);
        let (coll2,_debt2,  is_active3) = cdp_multi::get_user_position<TestCoin2>(user_addr);

        // std::debug::print(&(std::string::utf8(b"coll1")));  
        // std::debug::print(&coll1);
        // std::debug::print(&(std::string::utf8(b"coll2")));  
        // std::debug::print(&coll2);

        // Verify collateral amounts and active status
        assert!(coll1 == 100 * SCALING_FACTOR, 0);
        assert!(is_active1, 1);
        assert!(coll2 == 50 * SCALING_FACTOR, 2);
        assert!(is_active3, 3);

        // Clean up
        coin::destroy_burn_cap<TestCoin>(burn_cap1);
        coin::destroy_burn_cap<TestCoin2>(burn_cap2);
        coin::destroy_freeze_cap<TestCoin>(freeze_cap1);
        coin::destroy_freeze_cap<TestCoin2>(freeze_cap2);
        coin::destroy_mint_cap<TestCoin>(mint_cap1);
        coin::destroy_mint_cap<TestCoin2>(mint_cap2);
    }

    #[test]
    #[expected_failure(location = positions,abort_code = events::ERR_POSITION_ALREADY_EXISTS)]
    fun test_cannot_open_duplicate_trove() {
        let (framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        block::initialize_for_test(&framework, 1); 

        // Initialize timestamp using framework account
        // timestamp::set_time_has_started_for_testing(&framework);

        // Initialize test coins
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
        setup_collector_accounts();


        // Register user for coins
        coin::register<TestCoin>(&user);
        coin::register<TestCoin2>(&user);
        coin::register<CASH>(&user);

        // Mint and deposit in one step to avoid unused coins
        coin::deposit(user_addr, coin::mint<TestCoin>(500 * SCALING_FACTOR, &mint_cap1));
        coin::deposit(user_addr, coin::mint<TestCoin2>(250 * SCALING_FACTOR, &mint_cap2));

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
            100,
            100,1,
            900
        );

        cdp_multi::add_collateral<TestCoin2>(
            &admin,
            40 * SCALING_FACTOR,  // higher min debt
            13000,               // higher MCR (130%)
            200,                // same borrow rate
            2 * SCALING_FACTOR,  // same liquidation reserve
            12000,              // higher liquidation threshold
            1000,               // same liquidation penalty
            50,                 // same redemption fee
            DECIMALS,
            100,
            100,1,
            900
        );

        // Set prices
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);  // $10
        cdp_multi::set_price<TestCoin2>(&admin, 20 * SCALING_FACTOR); // $20

        // Register user for all coins
        coin::register<TestCoin>(&user);
        coin::register<TestCoin2>(&user);
        coin::register<CASH>(&user);

        // Open troves
        cdp_multi::open_trove<TestCoin>(&user, 100 * SCALING_FACTOR, 500 * SCALING_FACTOR);
        cdp_multi::open_trove<TestCoin>(&user, 100 * SCALING_FACTOR, 400 * SCALING_FACTOR);

         // Clean up
        coin::destroy_burn_cap<TestCoin>(burn_cap1);
        coin::destroy_burn_cap<TestCoin2>(burn_cap2);
        coin::destroy_freeze_cap<TestCoin>(freeze_cap1);
        coin::destroy_freeze_cap<TestCoin2>(freeze_cap2);
        coin::destroy_mint_cap<TestCoin>(mint_cap1);
        coin::destroy_mint_cap<TestCoin2>(mint_cap2);
    }

    #[test]
    fun test_trove_lifecycle() {
        let (framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        block::initialize_for_test(&framework, 1); 
        // setup_collector_accounts();  
        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        // timestamp::set_time_has_started_for_testing(&framework);

        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 

        // Setup collateral config
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
            100,
            100,1,
            900
        );

        // Set price and register coins
        cdp_multi::set_price<SupraCoin>(&admin, 50 * SCALING_FACTOR); // $50
        coin::register<SupraCoin>(&admin); // Register admin (CDP contract) for SupraCoin
        coin::register<SupraCoin>(&user);
        coin::register<CASH>(&fee_collector);
        coin::register<SupraCoin>(&fee_collector);
    
        // Give user initial SUPRA
        let initial_supra = 1000 * SCALING_FACTOR;
        coin::deposit(user_addr, coin::mint(initial_supra, &mint_cap));

        // 1. Open Trove
        let collateral = 200 * SCALING_FACTOR; // 200 SUPRA ($10,000 worth)
        let borrow_amount = 5000 * SCALING_FACTOR; // 5000 debtToken (50% collateral ratio)
        cdp_multi::open_trove<SupraCoin>(&user, collateral, borrow_amount);

        // Verify user became redemption provider after opening trove
        assert!(cdp_multi::is_redemption_provider<SupraCoin>(user_addr), 100);

        // Verify initial position
        let (coll, debt, is_active) = cdp_multi::get_user_position<SupraCoin>(user_addr);
        assert!(coll == collateral, 0);
        assert!(is_active, 1);
        let borrow_fee = (borrow_amount * 200) / 10000; // 2% fee
        let expected_debt = borrow_amount + borrow_fee + (2 * SCALING_FACTOR); // Including liquidation reserve
        assert!(debt == expected_debt, 2);

        // 2. Deposit More Collateral and Mint More debtToken
        let additional_collateral = 50 * SCALING_FACTOR;
        let additional_borrow = 1000 * SCALING_FACTOR;
        cdp_multi::deposit_or_mint<SupraCoin>(&user, additional_collateral, additional_borrow);

        // Verify updated position
        let (new_coll, new_debt, _) = cdp_multi::get_user_position<SupraCoin>(user_addr);
        assert!(new_coll == collateral + additional_collateral, 3);
        let additional_fee = (additional_borrow * 200) / 10000;
        assert!(new_debt == expected_debt + additional_borrow + additional_fee, 4);

        // 3. Repay Some Debt and Withdraw Some Collateral
        let repay_amount = 2000 * SCALING_FACTOR;
        let withdraw_amount = 20 * SCALING_FACTOR;
        
        std::debug::print(&(std::string::utf8(b"debt before")));  
        std::debug::print(&new_debt);
        std::debug::print(&(std::string::utf8(b"coll before")));  
        std::debug::print(&new_coll);
        cdp_multi::repay_or_withdraw<SupraCoin>(&user, withdraw_amount, repay_amount);

        // Verify position after repayment
        let (final_coll, final_debt, _) = cdp_multi::get_user_position<SupraCoin>(user_addr);
        std::debug::print(&(std::string::utf8(b"final_debt after")));  
        std::debug::print(&final_debt);
        std::debug::print(&(std::string::utf8(b"coll vafter")));  
        std::debug::print(&final_coll);
        assert!(final_coll == new_coll - withdraw_amount, 5);
        assert!(final_debt == new_debt - repay_amount, 6);

        // // 4. Close Trove
        // Get LR collector balance before close
        let lr_collector = cdp_multi::get_lr_collector();
        let lr_balance_before = coin::balance<CASH>(lr_collector);

        // Get remaining debt excluding liquidation reserve
        let (_, debt_amount, _) = cdp_multi::get_user_position<SupraCoin>(user_addr);
        let liquidation_reserve = 2 * SCALING_FACTOR;
        let debt_to_repay = debt_amount - liquidation_reserve;

        // Mint debtToken needed for repayment
        cdp_multi::mint_debtToken_for_test(user_addr, debt_to_repay);

        // Close trove
        cdp_multi::close_trove<SupraCoin>(&user);

        // Verify liquidation reserve was burned
        let lr_balance_after = coin::balance<CASH>(lr_collector);
        assert!(lr_balance_after == lr_balance_before - liquidation_reserve, 8);

        // Verify trove is closed
        let (closed_coll, closed_debt, still_active) = cdp_multi::get_user_position<SupraCoin>(user_addr);
        assert!(closed_coll == 0 && closed_debt == 0 && !still_active, 7);
        
        

        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }


    #[test]
    fun test_multi_trove_lifecycle() {
        let (framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        block::initialize_for_test(&framework, 1); 

        // Initialize test coins
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
        setup_collector_accounts();

        // Setup collateral configurations
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            20 * SCALING_FACTOR,  // min debt
            12500,               // MCR (125%)
            200,                // borrow rate (2%)
            2 * SCALING_FACTOR,  // liquidation reserve
            11500,              // liquidation threshold
            1000,               // liquidation penalty
            50,                 // redemption fee
            DECIMALS,
            100,
            100,1,
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
            100,
            100,1,
            900
        );

        // Set prices
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);  // $10
        cdp_multi::set_price<TestCoin2>(&admin, 20 * SCALING_FACTOR); // $20

        // Register user for coins
        coin::register<TestCoin>(&user);
        coin::register<TestCoin2>(&user);
        coin::register<CASH>(&user);

        // Give user initial coins
        coin::deposit(user_addr, coin::mint<TestCoin>(500 * SCALING_FACTOR, &mint_cap1));
        coin::deposit(user_addr, coin::mint<TestCoin2>(250 * SCALING_FACTOR, &mint_cap2));

        // 1. Open Troves
        let collateral1 = 100 * SCALING_FACTOR;
        let borrow_amount1 = 500 * SCALING_FACTOR;
        cdp_multi::open_trove<TestCoin>(&user, collateral1, borrow_amount1);

        let collateral2 = 50 * SCALING_FACTOR;
        let borrow_amount2 = 400 * SCALING_FACTOR;
        cdp_multi::open_trove<TestCoin2>(&user, collateral2, borrow_amount2);

        // 2. Deposit More Collateral and Mint More debtToken for both troves
        let additional_collateral1 = 20 * SCALING_FACTOR;
        let additional_borrow1 = 100 * SCALING_FACTOR;
        cdp_multi::deposit_or_mint<TestCoin>(&user, additional_collateral1, additional_borrow1);

        let additional_collateral2 = 10 * SCALING_FACTOR;
        let additional_borrow2 = 80 * SCALING_FACTOR;
        cdp_multi::deposit_or_mint<TestCoin2>(&user, additional_collateral2, additional_borrow2);

        // 3. Repay Some Debt and Withdraw Some Collateral from both troves
        let repay_amount1 = 200 * SCALING_FACTOR;
        let withdraw_amount1 = 10 * SCALING_FACTOR;
        cdp_multi::repay_or_withdraw<TestCoin>(&user, withdraw_amount1, repay_amount1);

        let repay_amount2 = 150 * SCALING_FACTOR;
        let withdraw_amount2 = 5 * SCALING_FACTOR;
        cdp_multi::repay_or_withdraw<TestCoin2>(&user, withdraw_amount2, repay_amount2);

        // 4. Close both Troves
        // Get remaining debt for first trove
        let (_, debt_amount1, _) = cdp_multi::get_user_position<TestCoin>(user_addr);
        let debt_to_repay1 = debt_amount1 - (2 * SCALING_FACTOR); // Subtract liquidation reserve
        cdp_multi::mint_debtToken_for_test(user_addr, debt_to_repay1);
        cdp_multi::close_trove<TestCoin>(&user);

        // Get remaining debt for second trove
        let (_, debt_amount2, _) = cdp_multi::get_user_position<TestCoin2>(user_addr);
        let debt_to_repay2 = debt_amount2 - (2 * SCALING_FACTOR); // Subtract liquidation reserve
        cdp_multi::mint_debtToken_for_test(user_addr, debt_to_repay2);
        cdp_multi::close_trove<TestCoin2>(&user);

        // Verify both troves are closed
        let (coll1, debt1, active1) = cdp_multi::get_user_position<TestCoin>(user_addr);
        let (coll2, debt2, active2) = cdp_multi::get_user_position<TestCoin2>(user_addr);
        assert!(coll1 == 0 && debt1 == 0 && !active1, 1);
        assert!(coll2 == 0 && debt2 == 0 && !active2, 2);

        // Clean up
        coin::destroy_burn_cap<TestCoin>(burn_cap1);
        coin::destroy_burn_cap<TestCoin2>(burn_cap2);
        coin::destroy_freeze_cap<TestCoin>(freeze_cap1);
        coin::destroy_freeze_cap<TestCoin2>(freeze_cap2);
        coin::destroy_mint_cap<TestCoin>(mint_cap1);
        coin::destroy_mint_cap<TestCoin2>(mint_cap2);
    }

        #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_BELOW_MINIMUM_DEBT)]
    fun test_cannot_repay_to_below_minimum_debt() {
        let (framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        block::initialize_for_test(&framework, 1); 

        // Initialize test coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );

        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        
        // Register fee collector for CASH and test coins
        coin::register<CASH>(&fee_collector);
        coin::register<TestCoin>(&fee_collector);

        // Register user for coins
        coin::register<TestCoin>(&user);
        coin::register<CASH>(&user);

        // Give user initial coins
        coin::deposit(user_addr, coin::mint<TestCoin>(500 * SCALING_FACTOR, &mint_cap));
        

        // Setup collateral config with minimum debt of 20 debtToken
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
            100,
            100,1,
            900
        );

        // Set price
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);  // $10

        // Open trove with 100 TEST ($1000) and borrow 50 debtToken
        cdp_multi::open_trove<TestCoin>(&user, 100 * SCALING_FACTOR, 50 * SCALING_FACTOR);

        // Try to repay 35 debtToken, which would leave only 15 debtToken debt
        // (below minimum debt of 20 + 2 liquidation reserve = 22 debtToken)
        cdp_multi::repay_or_withdraw<TestCoin>(&user, 0, 35 * SCALING_FACTOR);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }


    #[test]
    fun test_operation_status() {
        let (_framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        // setup_collector_accounts();
        block::initialize_for_test(&_framework, 1); 

        // Initialize test coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );

        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        
        // Register fee collector for CASH and test coins
        coin::register<CASH>(&fee_collector);
        coin::register<TestCoin>(&fee_collector);
        // coin::register<TestCoin2>(&fee_collector);

        // Register coins
        coin::register<TestCoin>(&user);
        coin::register<CASH>(&user);
        
        // Give user initial coins
        coin::deposit(user_addr, coin::mint<TestCoin>(500 * SCALING_FACTOR, &mint_cap));

        // Add collateral with all operations enabled (default)
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
            100,
            100,1,
            900
        );

        // Set price
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);

        // Verify initial status (all operations enabled)
        let (open_trove, borrow, deposit, redeem) = cdp_multi::get_operation_status<TestCoin>();
        assert!(open_trove && borrow && deposit && redeem, 0);

        // Disable borrow and redeem operations
        cdp_multi::set_operation_status<TestCoin>(&admin, true, false, true, false);
        
        // Verify updated status
        let (open_trove, borrow, deposit, redeem) = cdp_multi::get_operation_status<TestCoin>();
        assert!(open_trove, 1);
        assert!(!borrow, 2);
        assert!(deposit, 3);
        assert!(!redeem, 4);

        // Open trove should still work
        cdp_multi::open_trove<TestCoin>(&user, 100 * SCALING_FACTOR, 50 * SCALING_FACTOR);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_OPERATION_DISABLED)]
    fun test_cannot_borrow_when_disabled() {
        let (_framework, admin, user) = setup_test();
        let user_addr = signer::address_of(&user);
        // setup_collector_accounts();
        block::initialize_for_test(&_framework, 1); 
        // Initialize test coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true

            
        );

        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        
        // Register fee collector for CASH and test coins
        coin::register<CASH>(&fee_collector);
        coin::register<TestCoin>(&fee_collector);

        // Setup coins and initial balance
        coin::register<TestCoin>(&user);
        coin::register<CASH>(&user);
        coin::deposit(user_addr, coin::mint<TestCoin>(500 * SCALING_FACTOR, &mint_cap));

        // Add collateral and set price
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            20 * SCALING_FACTOR,
            12500,
            200,
            2 * SCALING_FACTOR,
            11500,
            1000,
            50,
            DECIMALS,
            100,
            100,1,
            900
        );
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR);

        // Open trove
        cdp_multi::open_trove<TestCoin>(&user, 100 * SCALING_FACTOR, 50 * SCALING_FACTOR);

        // Disable borrow operation
        cdp_multi::set_operation_status<TestCoin>(&admin, true, false, true, true);

        // Try to borrow more (should fail)
        cdp_multi::deposit_or_mint<TestCoin>(&user, 0, 10 * SCALING_FACTOR);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(location = cdp_multi,abort_code = events::ERR_NOT_ADMIN)]
    fun test_only_admin_can_set_status() {
        let (_framework, _admin, user) = setup_test();
        block::initialize_for_test(&_framework, 1); 
        // Try to set status as non-admin (should fail)
        cdp_multi::set_operation_status<TestCoin>(&user, true, true, true, true);
    }
}