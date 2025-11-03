#[test_only]
module cdp::cdp_multi_red_tests {
    use std::signer;
    use std::string;
    use std::fixed_point32;
    use supra_framework::coin;
    use supra_framework::account;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use cdp::events;
    use supra_framework::block;
    use cdp::cdp_multi::{Self, CASH};
    use supra_framework::timestamp;

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
        coin::register<TestCoin>(&fee_collector);
        // coin::register<TestCoin2>(&fee_collector);
        // coin::register<SupraCoin>(&fee_collector);
    }

    fun setup_collector_accountsmulti() {
        let fee_collector = account::create_account_for_test(cdp_multi::get_fee_collector());
        
        // Register fee collector for CASH and test coins
        coin::register<CASH>(&fee_collector);
        coin::register<TestCoin>(&fee_collector);
        // coin::register<TestCoin2>(&fee_collector);
        // coin::register<SupraCoin>(&fee_collector);
    }

    #[test]
    fun test_successful_redemption() {
        let (framework_signer, admin, provider) = setup_test();
        let redeemer = account::create_account_for_test(@0x789);
        let provider_addr = signer::address_of(&provider);
        let redeemer_addr = signer::address_of(&redeemer);
        block::initialize_for_test(&framework_signer, 1); 
        // Initialize test coins
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );
        setup_collector_accounts();

        // Setup collateral config
        cdp_multi::add_collateral<TestCoin>(
            &admin,
            20 * SCALING_FACTOR,  // min debt
            12500,               // MCR (125%)
            200,                // borrow rate
            2 * SCALING_FACTOR,  // liquidation reserve
            11500,              // liquidation threshold
            1000,               // liquidation penalty
            50,                 // redemption fee (0.5%)
            DECIMALS,
            100,
            100,1,
            900
        );

        // Set price and register coins
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR); // $10
        coin::register<TestCoin>(&provider);
        coin::register<CASH>(&provider);
        coin::register<TestCoin>(&redeemer);
        coin::register<CASH>(&redeemer);

        // Setup provider's trove
        let initial_collateral = 1000 * SCALING_FACTOR; // 1000 TEST
        let initial_borrow = 400 * SCALING_FACTOR;      // 400 debtToken
        coin::deposit(provider_addr, coin::mint(initial_collateral, &mint_cap));
        cdp_multi::open_trove<TestCoin>(&provider, initial_collateral, initial_borrow);

        // Give redeemer debtToken coins
        let redemption_amount = 100 * SCALING_FACTOR; // 100 debtToken
        cdp_multi::mint_debtToken_for_test(redeemer_addr, redemption_amount);

        // Record initial balances and position
        let initial_redeemer_test = coin::balance<TestCoin>(redeemer_addr);
        let (_, initial_debt, _) = cdp_multi::get_user_position<TestCoin>(provider_addr);

        // Get config to calculate expected redemption amount
        let (min_debt, _, _, liquidation_reserve, _, _, _, _, _, _) = cdp_multi::get_collateral_config<TestCoin>();
        
        // Calculate actual redemption amount based on contract logic
        let actual_redemption_amount = if (redemption_amount >= initial_debt - liquidation_reserve) {
            initial_debt - liquidation_reserve
        } else {
            let remaining_debt = initial_debt - redemption_amount;
            if (remaining_debt < min_debt + liquidation_reserve) {
                initial_debt - (min_debt + liquidation_reserve)
            } else {    
                redemption_amount
            }
        };

        // Calculate expected TEST amount (considering price and fee)
        let price = cdp_multi::get_collateral_price<TestCoin>();
        let expected_collateral = fixed_point32::divide_u64(actual_redemption_amount, price);
        let fee = (expected_collateral * 50) / 10000; // 0.5% fee
        let user_gratuity_fee = (expected_collateral * 100) / 10000; // 1% gratuity fee
        let expected_collateral_after_fee = expected_collateral - fee - user_gratuity_fee;
        
        // Set min_collateral_out with 1% slippage tolerance
        let min_collateral_out = (expected_collateral_after_fee * 9900) / 10000; // 99% of expected value

        // Execute redemption with slippage protection
        cdp_multi::redeem<TestCoin>(&redeemer, provider_addr, redemption_amount, min_collateral_out);

        // Verify redeemer received correct amount of TEST
        let final_redeemer_test = coin::balance<TestCoin>(redeemer_addr);
        assert!(final_redeemer_test - initial_redeemer_test == expected_collateral_after_fee, 0);

        // Verify provider's debt was reduced by the actual redemption amount
        let (_, final_debt, _) = cdp_multi::get_user_position<TestCoin>(provider_addr);
        assert!(initial_debt - final_debt == actual_redemption_amount, 1);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_redemption_with_excess_collateral() {
        let (framework_signer, admin, provider) = setup_test();
        let redeemer = account::create_account_for_test(@0x789);
        let provider_addr = signer::address_of(&provider);
        let redeemer_addr = signer::address_of(&redeemer);
        block::initialize_for_test(&framework_signer, 1); 

        // Initialize test coins
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );
        setup_collector_accounts();

        // Setup collateral config
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

        // Set price and register coins
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR); // $10
        coin::register<TestCoin>(&provider);
        coin::register<CASH>(&provider);
        coin::register<TestCoin>(&redeemer);
        coin::register<CASH>(&redeemer);

        // Setup provider's trove with excess collateral
        let initial_collateral = 1000 * SCALING_FACTOR; // 1000 TEST
        let initial_borrow = 400 * SCALING_FACTOR;      // 400 debtToken
        coin::deposit(provider_addr, coin::mint(initial_collateral, &mint_cap));
        cdp_multi::open_trove<TestCoin>(&provider, initial_collateral, initial_borrow);

        // Get total debt and config
        let (_, debt, _) = cdp_multi::get_user_position<TestCoin>(provider_addr);
        let (min_debt, _, _, liquidation_reserve, _, _, _, _, _, _) = cdp_multi::get_collateral_config<TestCoin>();
        let max_redeemable = debt - liquidation_reserve;

        // Calculate actual redemption amount based on contract logic
        let actual_redemption_amount = if (max_redeemable >= debt - liquidation_reserve) {
            debt - liquidation_reserve
        } else {
            let remaining_debt = debt - max_redeemable;
            if (remaining_debt < min_debt + liquidation_reserve) {
                debt - (min_debt + liquidation_reserve)
            } else {    
                max_redeemable
            }
        };

        // Give redeemer enough debtToken for full redemption
        cdp_multi::mint_debtToken_for_test(redeemer_addr, actual_redemption_amount);

        // Record initial balances
        let initial_redeemer_test = coin::balance<TestCoin>(redeemer_addr);
        let lr_collector_initial_debtToken = coin::balance<CASH>(cdp_multi::get_lr_collector());

        // Calculate expected TEST amount (considering price and fee)
        let price = cdp_multi::get_collateral_price<TestCoin>();
        let expected_collateral = fixed_point32::divide_u64(actual_redemption_amount, price);
        let fee = (expected_collateral * 50) / 10000; // 0.5% fee
        let user_gratuity_fee = (expected_collateral * 100) / 10000; // 1% gratuity fee
        let expected_collateral_after_fee = expected_collateral - fee - user_gratuity_fee;
        
        // Set min_collateral_out with 1% slippage tolerance
        let min_collateral_out = (expected_collateral_after_fee * 9900) / 10000; // 99% of expected value
        
        // Execute redemption with slippage protection
        cdp_multi::redeem<TestCoin>(&redeemer, provider_addr, max_redeemable, min_collateral_out);

        let lr_collector_final_debtToken = coin::balance<CASH>(cdp_multi::get_lr_collector());
        assert!(lr_collector_final_debtToken == lr_collector_initial_debtToken - liquidation_reserve, 2);

        // Verify redeemer received correct amount of TEST
        let final_redeemer_test = coin::balance<TestCoin>(redeemer_addr);
        assert!(final_redeemer_test - initial_redeemer_test == expected_collateral_after_fee, 0);

        // Verify trove is closed
        let (final_debt, final_coll, is_active) = cdp_multi::get_user_position<TestCoin>(provider_addr);
        assert!(final_debt == 0 && final_coll == 0 && !is_active, 1);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_redeem_multiple() {
        let (framework_signer, admin, _) = setup_test();
        let provider1 = account::create_account_for_test(@0x456);
        let provider2 = account::create_account_for_test(@0x457);
        let redeemer = account::create_account_for_test(@0x789);
        
        let provider1_addr = signer::address_of(&provider1);
        let provider2_addr = signer::address_of(&provider2);
        let redeemer_addr = signer::address_of(&redeemer);

        block::initialize_for_test(&framework_signer, 1); 
        // Initialize test coins
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );
        setup_collector_accounts();

        // Setup collateral config
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

        // Set price and register coins
        cdp_multi::set_price<TestCoin>(&admin, 10 * SCALING_FACTOR); // $10
        coin::register<TestCoin>(&provider1);
        coin::register<CASH>(&provider1);
        coin::register<TestCoin>(&provider2);
        coin::register<CASH>(&provider2);
        coin::register<TestCoin>(&redeemer);
        coin::register<CASH>(&redeemer);

        // Setup provider1's trove
        let initial_collateral1 = 1000 * SCALING_FACTOR; // 1000 TEST
        let initial_borrow1 = 400 * SCALING_FACTOR;      // 400 debtToken
        coin::deposit(provider1_addr, coin::mint(initial_collateral1, &mint_cap));
        cdp_multi::open_trove<TestCoin>(&provider1, initial_collateral1, initial_borrow1);

        // Setup provider2's trove
        let initial_collateral2 = 2000 * SCALING_FACTOR; // 2000 TEST
        let initial_borrow2 = 800 * SCALING_FACTOR;      // 800 debtToken
        coin::deposit(provider2_addr, coin::mint(initial_collateral2, &mint_cap));
        cdp_multi::open_trove<TestCoin>(&provider2, initial_collateral2, initial_borrow2);

        // Get config and calculate actual redemption amounts
        let (min_debt, _, _, liquidation_reserve, _, _, _, _, _, _) = cdp_multi::get_collateral_config<TestCoin>();
        
        // Record initial states and balances
        let (_,initial_debt1, _) = cdp_multi::get_user_position<TestCoin>(provider1_addr);
        let (_,initial_debt2,  _) = cdp_multi::get_user_position<TestCoin>(provider2_addr);
        let initial_redeemer_test = coin::balance<TestCoin>(redeemer_addr);
        let lr_collector_initial_debtToken = coin::balance<CASH>(cdp_multi::get_lr_collector());

        // Calculate actual redemption amounts based on contract logic
        let redemption_amount1 = 100 * SCALING_FACTOR; // 100 debtToken
        let actual_redemption1 = if (redemption_amount1 >= initial_debt1 - liquidation_reserve) {
            initial_debt1 - liquidation_reserve
        } else {
            let remaining_debt = initial_debt1 - redemption_amount1;
            if (remaining_debt < min_debt + liquidation_reserve) {
                initial_debt1 - (min_debt + liquidation_reserve)
            } else {    
                redemption_amount1
            }
        };

        let redemption_amount2 = 200 * SCALING_FACTOR; // 200 debtToken
        let actual_redemption2 = if (redemption_amount2 >= initial_debt2 - liquidation_reserve) {
            initial_debt2 - liquidation_reserve
        } else {
            let remaining_debt = initial_debt2 - redemption_amount2;
            if (remaining_debt < min_debt + liquidation_reserve) {
                initial_debt2 - (min_debt + liquidation_reserve)
            } else {    
                redemption_amount2
            }
        };

        // Give redeemer debtToken coins
        cdp_multi::mint_debtToken_for_test(redeemer_addr, actual_redemption1 + actual_redemption2);

        // Calculate expected collateral amounts
        let price = cdp_multi::get_collateral_price<TestCoin>();
        let expected_collateral1 = fixed_point32::divide_u64(actual_redemption1, price);
        let fee1 = (expected_collateral1 * 50) / 10000; // 0.5% fee
        let user_gratuity_fee1 = (expected_collateral1 * 100) / 10000; // 1% gratuity fee
        let expected_collateral1_after_fee = expected_collateral1 - fee1 - user_gratuity_fee1;
        
        let expected_collateral2 = fixed_point32::divide_u64(actual_redemption2, price);
        let fee2 = (expected_collateral2 * 50) / 10000; // 0.5% fee
        let user_gratuity_fee2 = (expected_collateral2 * 100) / 10000; // 1% gratuity fee
        let expected_collateral2_after_fee = expected_collateral2 - fee2 - user_gratuity_fee2;
        
        // Set min_collateral_out values with 1% slippage tolerance
        let min_collateral_out1 = (expected_collateral1_after_fee * 9900) / 10000; // 99% of expected value
        let min_collateral_out2 = (expected_collateral2_after_fee * 9900) / 10000; // 99% of expected value
        
        // Execute multiple redemption with slippage protection
        let providers = vector[provider1_addr, provider2_addr];
        let amounts = vector[redemption_amount1, redemption_amount2];
        let min_collateral_outs = vector[min_collateral_out1, min_collateral_out2];
        cdp_multi::redeem_multiple<TestCoin>(&redeemer, providers, amounts, min_collateral_outs);

        // Verify redeemer received correct amount of TEST
        let final_redeemer_test = coin::balance<TestCoin>(redeemer_addr);
        assert!(final_redeemer_test - initial_redeemer_test == (expected_collateral1_after_fee + expected_collateral2_after_fee), 0);

        // Verify debts were reduced correctly
        let (_,final_debt1,  _) = cdp_multi::get_user_position<TestCoin>(provider1_addr);
        let ( _,final_debt2, _) = cdp_multi::get_user_position<TestCoin>(provider2_addr);
        assert!(initial_debt1 - final_debt1 == actual_redemption1, 1);
        assert!(initial_debt2 - final_debt2 == actual_redemption2, 2);

        // Verify liquidation reserve handling if troves are closed
        let lr_collector_final_debtToken = coin::balance<CASH>(cdp_multi::get_lr_collector());
        let expected_lr_burn = if (final_debt1 == 0) { liquidation_reserve } else { 0 } +
                              if (final_debt2 == 0) { liquidation_reserve } else { 0 };
        assert!(lr_collector_final_debtToken == lr_collector_initial_debtToken - expected_lr_burn, 3);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = events::ERR_INVALID_ARRAY_LENGTH, location = cdp_multi)]
    fun test_redeem_multiple_mismatched_arrays() {
        let (framework_signer, admin, _) = setup_test();
        let provider = account::create_account_for_test(@0x456);
        let redeemer = account::create_account_for_test(@0x789);

        block::initialize_for_test(&framework_signer, 1); 
        // Initialize test coins
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            &admin,
            string::utf8(b"Test Coin"),
            string::utf8(b"TEST"),
            DECIMALS,
            true
        );
        setup_collector_accounts();

        // Create mismatched vectors
        let providers = vector[signer::address_of(&provider)];
        let amounts = vector[100 * SCALING_FACTOR, 200 * SCALING_FACTOR]; // Two amounts for one provider
        let min_collateral_outs = vector[10 * SCALING_FACTOR]; // Only one min_collateral_out value

        // This should fail due to mismatched array lengths
        cdp_multi::redeem_multiple<TestCoin>(&redeemer, providers, amounts, min_collateral_outs);

        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);
    }
    


}