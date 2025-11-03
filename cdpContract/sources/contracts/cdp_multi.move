module cdp::cdp_multi {
    use std::signer;
    use std::string;
    use std::vector;
    use aptos_std::type_info::{Self, TypeInfo};
    use std::fixed_point32::{Self, FixedPoint32};
    use aptos_std::table::{Self, Table};
    use supra_framework::coin::{Self, BurnCapability, FreezeCapability, MintCapability};
    use supra_framework::account;
    use supra_framework::timestamp;    
    use cdp::enhanced_price_oracle;
    use cdp::price_oracle;
    use cdp::config;
    use cdp::positions;
    use supra_framework::block;
    use cdp::events;
    use supra_framework::math64;

    struct SignerCapability has key {
        cap: account::SignerCapability
    }

    struct LRCollectorCapability has key {
        cap: account::SignerCapability
    }

    struct TroveManager has key {
        debtToken_mint_cap: MintCapability<CASH>,
        debtToken_burn_cap: BurnCapability<CASH>,
        debtToken_freeze_cap: FreezeCapability<CASH>,
        total_collateral: Table<TypeInfo, u64>,  // Track total collateral per type
        total_debt: Table<TypeInfo, u64>,       // Track total debt per type
    }

    struct CASH has store { value: u64 }


    public entry fun initialize(admin: &signer, fee_collector: address) {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        price_oracle::initialize(admin);
        config::initialize(admin, fee_collector);
        positions::initialize(admin);
        // Initialize debtToken coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CASH>(
            admin,
            string::utf8(b"Solido Stablecoin"),
            string::utf8(b"CASH"),
            8,
            true
        );
        // Create resource account for CDP pool
        let (_resource_signer, signer_cap) = account::create_resource_account(admin, b"cdp_pool");
        move_to(admin, SignerCapability { cap: signer_cap });
        // Create LR_COLLECTOR account and capability
        let (lr_collector_signer, lr_collector_cap) = account::create_resource_account(admin, b"lr_collector");
        if (!coin::is_account_registered<CASH>(signer::address_of(&lr_collector_signer))) {
            coin::register<CASH>(&lr_collector_signer);
        };
        move_to(admin, LRCollectorCapability { cap: lr_collector_cap });
        move_to(admin, TroveManager {
            debtToken_mint_cap: mint_cap,
            debtToken_burn_cap: burn_cap,
            debtToken_freeze_cap: freeze_cap,
            total_collateral: table::new(),
            total_debt: table::new(),
        });
    }

    public entry fun add_collateral<CoinType>(
        admin: &signer,
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_reserve: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        redemption_fee: u64,
        decimals: u8,
        liquidation_fee_protocol: u64,
        redemption_fee_gratuity:u64,
        oracle_id: u32,
        price_age: u64
    ) acquires  SignerCapability  {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        // Check if coin is initialized - fail if not
        assert!(coin::is_coin_initialized<CoinType>(), events::err_coin_not_initialized());
        
        config::add_collateral<CoinType>( minimum_debt, mcr, borrow_rate, liquidation_reserve, liquidation_threshold, liquidation_penalty, redemption_fee, decimals, liquidation_fee_protocol, redemption_fee_gratuity, oracle_id, price_age);
        // Register resource account for the collateral coin type
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        if (!coin::is_account_registered<CoinType>(signer::address_of(&resource_signer))) {
            coin::register<CoinType>(&resource_signer);
        };
        
    }

    public entry fun register_debtToken_coin(account: &signer) {
        if (!coin::is_account_registered<CASH>(signer::address_of(account))) {
            coin::register<CASH>(account);
        }
    }

    public entry fun register_collateral_coin<CoinType>(account: &signer) {
        if (!coin::is_account_registered<CoinType>(signer::address_of(account))) {
            coin::register<CoinType>(account);
        }
    }

    public entry fun register_as_redemption_provider<CoinType>(
        user: &signer,
        opt_in: bool
    )  {
        positions::register_redemption_provider<CoinType>(signer::address_of(user), opt_in);
    }

    public entry fun open_trove<CoinType>(
        user: &signer,
        collateral_deposit: u64,
        debtToken_mint: u64
    ) acquires TroveManager, SignerCapability, LRCollectorCapability {
        let user_addr = signer::address_of(user);
        let collateral_type = type_info::type_of<CoinType>();

        // Get collateral config and verify it's enabled
        let (open_trove_enabled, _, _, _) = config::get_operation_status<CoinType>();
        assert!(open_trove_enabled, events::err_operation_disabled());
        assert!(config::is_valid_collateral<CoinType>(), events::err_collateral_disabled());
        // Get config values
        let minimum_debt = config::get_minimum_debt<CoinType>();
        let liquidation_reserve = config::get_liquidation_reserve<CoinType>();
        let borrow_rate = config::get_borrow_rate<CoinType>();
        
        assert!(debtToken_mint >= minimum_debt, events::err_below_minimum_debt());

        // Calculate total debt including fees
        let borrow_fee = (debtToken_mint * borrow_rate) / 10000;
        let total_debt_amount = debtToken_mint + borrow_fee + liquidation_reserve;

        // Verify collateral ratio
        verify_collateral_ratio<CoinType>(collateral_deposit, total_debt_amount);

        // Get resource account for transfer
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resource_addr = signer::address_of(&resource_signer);

        // Transfer collateral to resource account instead of CDP directly
        coin::transfer<CoinType>(user, resource_addr, collateral_deposit);

        // Register user for CASH if needed
        if (!coin::is_account_registered<CASH>(user_addr)) {
            coin::register<CASH>(user);
        };

        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        
        // Update total stats with per-type debt tracking
        if (!table::contains(&vault_manager.total_collateral, collateral_type)) {
            table::add(&mut vault_manager.total_collateral, collateral_type, 0);
            table::add(&mut vault_manager.total_debt, collateral_type, 0);
        };
        
        let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
        let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
        *total_collateral = *total_collateral + collateral_deposit;
        *total_debt = *total_debt + total_debt_amount;
        
        // Mint requested amount to user
        let debtToken_coins = coin::mint(debtToken_mint, &vault_manager.debtToken_mint_cap);
        coin::deposit(user_addr, debtToken_coins);

        // Mint borrow fee to fee collector
        let fee_coins = coin::mint(borrow_fee, &vault_manager.debtToken_mint_cap);
        coin::deposit(config::get_fee_collector(), fee_coins);

        // Mint liquidation reserve
        let lr_coins = coin::mint(liquidation_reserve, &vault_manager.debtToken_mint_cap);
        coin::deposit(get_lr_collector(), lr_coins);

        // Create position using positions module
        positions::create_position<CoinType>(
            user_addr,
            collateral_deposit,
            total_debt_amount,
            timestamp::now_seconds()
        );
        // Register as redemption provider
        positions::register_redemption_provider<CoinType>(user_addr, true);

        events::emit_trove_opened(user_addr, collateral_type, collateral_deposit, total_debt_amount, timestamp::now_seconds());
        events::emit_trove_updated_event(user_addr, collateral_type, collateral_deposit, total_debt_amount, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_open());
        
    }

    public entry fun deposit_or_mint<CoinType>(
        user: &signer,
        collateral_deposit: u64,
        debtToken_mint: u64
    ) acquires TroveManager, SignerCapability {
        let user_addr = signer::address_of(user);


        let collateral_type = type_info::type_of<CoinType>();
        
        positions::assert_position_exists<CoinType>(user_addr);
        
        let (current_collateral, current_debt, _, _) = positions::get_position<CoinType>(user_addr);
        let borrow_rate = config::get_borrow_rate<CoinType>();
        // Calculate new totals
        let new_collateral = current_collateral + collateral_deposit;
        let borrow_fee = (debtToken_mint * borrow_rate) / 10000;
        let new_debt = current_debt + debtToken_mint + borrow_fee;

        // Verify MCR
        // verify_collateral_ratio<CoinType>(new_collateral, new_debt);


        let (_, borrow_enabled, deposit_enabled, _) = config::get_operation_status<CoinType>();
        // Handle collateral deposit
        if (collateral_deposit > 0) {
            let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
            let resource_signer = account::create_signer_with_capability(signer_cap);
            let resource_addr = signer::address_of(&resource_signer);
            // assert!(status.deposit, events::err_operation_disabled());
            assert!(deposit_enabled, events::err_operation_disabled());
            coin::transfer<CoinType>(user, resource_addr, collateral_deposit);
            
            // Update total collateral
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
            *total_collateral = *total_collateral + collateral_deposit;

            events::emit_collateral_deposit_event(user_addr, collateral_type, collateral_deposit,  timestamp::now_seconds());
        };

        // Handle debtToken minting
        if (debtToken_mint > 0) {
            verify_collateral_ratio<CoinType>(new_collateral, new_debt);
            if (!coin::is_account_registered<CASH>(user_addr)) {
                coin::register<CASH>(user);
            };
            // assert!(status.borrow, events::err_operation_disabled());
            assert!(borrow_enabled, events::err_operation_disabled());
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
            *total_debt = *total_debt + debtToken_mint + borrow_fee;
            
            // Mint debtToken to user
            let debtToken_coins = coin::mint(debtToken_mint, &vault_manager.debtToken_mint_cap);
            coin::deposit(user_addr, debtToken_coins);

            // Mint borrow fee
            let fee_coins = coin::mint(borrow_fee, &vault_manager.debtToken_mint_cap);
            coin::deposit(config::get_fee_collector(), fee_coins);

            events::emit_debt_minted_event(user_addr, collateral_type, debtToken_mint, borrow_fee, timestamp::now_seconds());
        };

        events::emit_trove_updated_event(user_addr, collateral_type, new_collateral, new_debt, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_adjust());

        // Update position
        positions::update_position<CoinType>(
            user_addr,
            new_collateral,
            new_debt,
            timestamp::now_seconds()
        );
    }

    public entry fun repay_or_withdraw<CoinType>(
        user: &signer,
        collateral_withdraw: u64,
        debtToken_repay: u64
    ) acquires   TroveManager, SignerCapability {
        let user_addr = signer::address_of(user);
        positions::assert_position_exists<CoinType>(user_addr);
        let collateral_type = type_info::type_of<CoinType>();
       
        // let position = table::borrow_mut(user_positions, collateral_type);
        let (current_collateral, current_debt, _, _) = positions::get_position<CoinType>(user_addr);
        
        // Verify balances
        assert!(current_collateral >= collateral_withdraw, events::err_insufficient_collateral_balance());
        assert!(current_debt >= debtToken_repay, events::err_insufficient_debt_balance());

        // Calculate new totals
        let new_collateral = current_collateral - collateral_withdraw;
        let new_debt = current_debt - debtToken_repay;

        // If debt remains, verify MCR
        if (new_debt > 0) {
            let minimum_debt = config::get_minimum_debt<CoinType>();
            let liquidation_reserve = config::get_liquidation_reserve<CoinType>();
            assert!(
                new_debt >= (minimum_debt + liquidation_reserve),
                events::err_below_minimum_debt()
            );
            // verify_collateral_ratio<CoinType>(new_collateral, new_debt);
        };

        // Handle collateral withdrawal
        if (collateral_withdraw > 0) {
            verify_collateral_ratio<CoinType>(new_collateral, new_debt);

            let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
            let resource_signer = account::create_signer_with_capability(signer_cap);
            
            coin::transfer<CoinType>(&resource_signer, user_addr, collateral_withdraw);
            
            // Update total collateral
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
            *total_collateral = *total_collateral - collateral_withdraw;
            events::emit_collateral_withdraw_event(user_addr, collateral_type, collateral_withdraw, timestamp::now_seconds());
        };

        // Handle debtToken repayment
        if (debtToken_repay > 0) {
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
            *total_debt = *total_debt - debtToken_repay;
            
            let debtToken_coins = coin::withdraw<CASH>(user, debtToken_repay);
            coin::burn(debtToken_coins, &vault_manager.debtToken_burn_cap);

            events::emit_debt_repaid_event(user_addr, collateral_type, debtToken_repay, timestamp::now_seconds());
        };
        events::emit_trove_updated_event(user_addr, collateral_type, new_collateral, new_debt, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_adjust());

         // Update or remove position
        if (new_collateral == 0 && new_debt == 0) {
            positions::remove_position<CoinType>(user_addr);
        } else {
            positions::update_position<CoinType>(
                user_addr,
                new_collateral,
                new_debt,
                timestamp::now_seconds()
            );
        };
    }

    public entry fun close_trove<CoinType>(
        user: &signer
    ) acquires   TroveManager, SignerCapability, LRCollectorCapability {
        let user_addr = signer::address_of(user);
        assert_trove_active<CoinType>(user_addr);
        let collateral_type = type_info::type_of<CoinType>();

        let (collateral_amount, debt_amount, _, _) = positions::get_position<CoinType>(user_addr);

        let liquidation_reserve = config::get_liquidation_reserve<CoinType>();
        let debt_to_repay = debt_amount - liquidation_reserve;

        // Ensure user has enough debtToken to repay debt (excluding liquidation reserve)
        assert!(coin::balance<CASH>(user_addr) >= debt_to_repay, events::err_insufficient_debt_balance());

        // Handle debtToken repayment from user
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let debtToken_coins = coin::withdraw<CASH>(user, debt_to_repay);
        coin::burn(debtToken_coins, &vault_manager.debtToken_burn_cap);

        let lr_coins = coin::withdraw<CASH>(
            &account::create_signer_with_capability(&borrow_global<LRCollectorCapability>(@cdp).cap),
            liquidation_reserve
        );
        coin::burn(lr_coins, &vault_manager.debtToken_burn_cap);

        // Return collateral to user
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        coin::transfer<CoinType>(&resource_signer, user_addr, collateral_amount);

        // Update total stats
        let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
        let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
        *total_collateral = *total_collateral - collateral_amount;
        *total_debt = *total_debt - debt_amount;

        // Remove from redemption providers
        positions::register_redemption_provider<CoinType>(user_addr, false);

        events::emit_trove_closed(user_addr, collateral_type,collateral_amount, debt_amount, timestamp::now_seconds());
        events::emit_trove_updated_event(user_addr, collateral_type, 0, 0, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_close());
        // Remove position
        positions::remove_position<CoinType>(user_addr);

        
    }

    public entry fun liquidate<CoinType>(
        liquidator: &signer,
        user_addr: address
    ) acquires  TroveManager, SignerCapability, LRCollectorCapability {
        let liquidator_addr = signer::address_of(liquidator);
        assert!(liquidator_addr != user_addr, events::err_self_liquidation());
        let collateral_type = type_info::type_of<CoinType>();
        
        // Get position and verify it exists
        positions::assert_position_exists<CoinType>(user_addr);
        let (collateral_amount, debt_amount, _, _) = positions::get_position<CoinType>(user_addr);
        // let config = table::borrow(&borrow_global<CollateralRegistry>(@cdp).configs, collateral_type);

        // Calculate ICR
        let price = enhanced_price_oracle::get_price<CoinType>();
        let collateral_decimals = config::get_collateral_decimals<CoinType>();
        let debt_decimals = 8;

        let collateral_value = fixed_point32::multiply_u64(collateral_amount, price);
        let adjusted_collateral_value = if (collateral_decimals < debt_decimals) {
            collateral_value * math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
        } else if (collateral_decimals > debt_decimals) {
            collateral_value / math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
        } else {
            collateral_value
        };
        
        let current_ratio = (adjusted_collateral_value * 10000) / debt_amount;

        // Get liquidation parameters from config
        let liquidation_threshold = config::get_liquidation_threshold<CoinType>();
        let liquidation_penalty = config::get_liquidation_penalty<CoinType>();
        let liquidation_fee_protocol = config::get_liquidation_fee_protocol<CoinType>();
        let liquidation_reserve = config::get_liquidation_reserve<CoinType>();

        // Verify position is liquidatable (ICR < liquidation threshold)
        assert!(current_ratio < liquidation_threshold, events::err_cannot_liquidate());

        if (current_ratio <= 10000) {
            // Transfer and burn debtToken from liquidator
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let debtToken_coins = coin::withdraw<CASH>(liquidator, debt_amount);
            coin::burn(debtToken_coins, &vault_manager.debtToken_burn_cap);
            // Transfer liquidation reserve to liquidator
            let lr_coins = coin::withdraw<CASH>(
                &account::create_signer_with_capability(&borrow_global<LRCollectorCapability>(@cdp).cap),
                liquidation_reserve
            );
            coin::deposit(signer::address_of(liquidator), lr_coins);
            // Get resource signer for transfers
            let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
            let resource_signer = account::create_signer_with_capability(signer_cap);

            // Transfer all collateral to liquidator since debt > collateral value
            coin::transfer<CoinType>(&resource_signer, signer::address_of(liquidator), collateral_amount);

            // Update total stats
            let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
            let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
            *total_collateral = *total_collateral - collateral_amount;
            *total_debt = *total_debt - debt_amount;

            events::emit_trove_liquidated(user_addr, signer::address_of(liquidator), collateral_type, collateral_amount, debt_amount, collateral_amount, 0, 0, timestamp::now_seconds());
            events::emit_trove_updated_event(user_addr, collateral_type, 0, 0, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_liquidate());
            // Remove position
            positions::remove_position<CoinType>(user_addr);    
            return
        };
        // Calculate penalty based on ICR if ICR > 100%
        let penalty_amount = if (current_ratio <= (10000 + liquidation_penalty)) {
            // For 100% < ICR <= 100% + lp: penalty = (x*p) - y
            adjusted_collateral_value - (debt_amount)
        } else {
            // For ICR > 100% + lp: penalty = lp*y
            (debt_amount * liquidation_penalty) / 10000
        };

        // let penalty_amount_in_collateral = fixed_point32::divide_u64(penalty_amount, price);
        let penalty_amount_in_collateral = if (collateral_decimals < debt_decimals) {
            fixed_point32::divide_u64(penalty_amount, price) / 
            math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
        } else if (collateral_decimals > debt_decimals) {
            fixed_point32::divide_u64(penalty_amount, price) * 
            math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
        } else {
            fixed_point32::divide_u64(penalty_amount, price)
        };
        let protocol_fee_in_collateral = (penalty_amount_in_collateral * liquidation_fee_protocol) / 10000;
        let liquidator_penalty_in_collateral = penalty_amount_in_collateral - protocol_fee_in_collateral;

        let debt_in_collateral = if (collateral_decimals < debt_decimals) {
            fixed_point32::divide_u64(debt_amount, price) / 
            math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
        } else if (collateral_decimals > debt_decimals) {
            fixed_point32::divide_u64(debt_amount, price) * 
            math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
        } else {
            fixed_point32::divide_u64(debt_amount, price)
        };
        // Calculate total penalty and possible refund

        let total_penalty_in_collateral = penalty_amount_in_collateral + debt_in_collateral;

        let liquidator_reward_in_collateral = liquidator_penalty_in_collateral + debt_in_collateral;
        
        let user_refund = if (total_penalty_in_collateral < collateral_amount) {
            collateral_amount - total_penalty_in_collateral
        } else {
            0
        };

        let available_for_liquidator = collateral_amount - protocol_fee_in_collateral - user_refund;
        
        // Take the minimum between calculated reward and available amount
        let liquidator_reward_in_collateral = if (liquidator_reward_in_collateral > available_for_liquidator) {
            available_for_liquidator
        } else {
            liquidator_reward_in_collateral
        };


        
        // Transfer and burn debtToken from liquidator
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let debtToken_coins = coin::withdraw<CASH>(liquidator, debt_amount);
        coin::burn(debtToken_coins, &vault_manager.debtToken_burn_cap);

        // Transfer liquidation reserve to liquidator instead of burning it
        let lr_coins = coin::withdraw<CASH>(
            &account::create_signer_with_capability(&borrow_global<LRCollectorCapability>(@cdp).cap),
            liquidation_reserve
        );
        coin::deposit(signer::address_of(liquidator), lr_coins);

        // Get resource signer for transfers
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);

        // Transfer protocol fee to fee collector
        if (protocol_fee_in_collateral > 0) {
            coin::transfer<CoinType>(&resource_signer, config::get_fee_collector(), protocol_fee_in_collateral);
        };

        // Transfer reward to liquidator
        coin::transfer<CoinType>(&resource_signer, signer::address_of(liquidator), liquidator_reward_in_collateral);

        // Transfer refund to liquidated user if any
        if (user_refund > 0) {
            coin::transfer<CoinType>(&resource_signer, user_addr, user_refund);
        };

        // Verify total distribution
        // assert!(liquidator_reward_in_collateral + protocol_fee_in_collateral + user_refund == collateral_amount, events::err_invalid_liquidation());
        // let distribution_sum = liquidator_reward_in_collateral + protocol_fee_in_collateral + user_refund;
        // assert!(distribution_sum <= collateral_amount, events::err_invalid_liquidation());

        // if (distribution_sum < collateral_amount) {
        //     assert!(collateral_amount - distribution_sum <= 100, events::err_invalid_liquidation());
        // };

        // Update total stats
        let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
        let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
        *total_collateral = *total_collateral - collateral_amount;
        *total_debt = *total_debt - debt_amount;

        events::emit_trove_liquidated(user_addr, signer::address_of(liquidator), collateral_type, collateral_amount, debt_amount, liquidator_reward_in_collateral, protocol_fee_in_collateral, user_refund, timestamp::now_seconds());
        events::emit_trove_updated_event(user_addr, collateral_type, 0, 0, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_liquidate());
        // Remove position
        positions::remove_position<CoinType>(user_addr);    
    }

    public entry fun partial_liquidate<CoinType>(
        liquidator: &signer,
        user_addr: address,
        debt_to_liquidate: u64
    ) acquires TroveManager, SignerCapability, LRCollectorCapability {
        let collateral_type = type_info::type_of<CoinType>();
        let liquidator_addr = signer::address_of(liquidator);
        assert!(liquidator_addr != user_addr, events::err_self_liquidation());
        
        // Get position and verify it exists
        positions::assert_position_exists<CoinType>(user_addr);
        let (collateral_amount, debt_amount, _, _) = positions::get_position<CoinType>(user_addr);
        
        // If full liquidation, call liquidate function
        if (debt_to_liquidate >= debt_amount) {
            liquidate<CoinType>(liquidator, user_addr);
            return
        };
        
        // Get parameters
        let minimum_debt = config::get_minimum_debt<CoinType>();
        let liquidation_reserve = config::get_liquidation_reserve<CoinType>();
        let liquidation_threshold = config::get_liquidation_threshold<CoinType>();
        let liquidation_penalty = config::get_liquidation_penalty<CoinType>();
        let liquidation_fee_protocol = config::get_liquidation_fee_protocol<CoinType>();

        // Calculate minimum liquidation chunk (0.1% of total debt)
        let min_liquidation_chunk = debt_amount / 1000; // 0.1% of debt_amount
        assert!(min_liquidation_chunk > 0, events::err_position_too_small_for_partial_liquidation());

        // Calculate how many chunks fit into debt_to_liquidate (truncate to integer multiple)
        let chunks = debt_to_liquidate / min_liquidation_chunk;
        assert!(chunks > 0, events::err_liquidation_amount_too_small());

        // Adjust debt_to_liquidate to be a multiple of min_liquidation_chunk
        let debt_to_liquidate = chunks * min_liquidation_chunk;
        
        // Verify remaining debt will be above minimum
        let remaining_debt = debt_amount - debt_to_liquidate;
        assert!(remaining_debt >= minimum_debt + liquidation_reserve, events::err_invalid_debt_amount());
        
        
        // Calculate ICR
        let price = enhanced_price_oracle::get_price<CoinType>();
        let collateral_decimals = config::get_collateral_decimals<CoinType>();
        let debt_decimals = 8;
        let collateral_value = fixed_point32::multiply_u64(collateral_amount, price);
        let adjusted_collateral_value = if (collateral_decimals < debt_decimals) {
            collateral_value * math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
        } else if (collateral_decimals > debt_decimals) {
            collateral_value / math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
        } else {
            collateral_value
        };
        let current_ratio = (adjusted_collateral_value * 10000) / debt_amount;

        // Verify position is liquidatable
        assert!(current_ratio < liquidation_threshold, events::err_cannot_liquidate());

        // Calculate proportional collateral to liquidate
        let collateral_amount_u128 = (collateral_amount as u128);
        let debt_to_liquidate_u128 = (debt_to_liquidate as u128);
        let debt_amount_u128 = (debt_amount as u128);
        
        let numerator = collateral_amount_u128 * debt_to_liquidate_u128;
        // Changed to always round down (floor division)
        let collateral_to_liquidate = ((numerator / debt_amount_u128) as u64);
        
        
         // Safety cap: don't exceed available collateral
        if (collateral_to_liquidate > collateral_amount) {
            collateral_to_liquidate = collateral_amount;
        };
        
        let (liquidator_reward_in_collateral, protocol_fee_in_collateral, user_refund) = if (current_ratio <= 10000) {
            // For ICR <= 100%: just proportional distribution, no penalties
            (collateral_to_liquidate, 0, 0)
        } else {
            // For ICR > 100%: calculate penalty
            let penalty_amount = if (current_ratio <= (10000 + liquidation_penalty)) {
                // For 100% < ICR <= 100% + lp: penalty = (x*p) - y
                // First, calculate collateral value with proper decimal adjustment
                let collateral_value = fixed_point32::multiply_u64(collateral_to_liquidate, price);
                let adjusted_collateral_value = if (collateral_decimals < debt_decimals) {
                    collateral_value * math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
                } else if (collateral_decimals > debt_decimals) {
                    collateral_value / math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
                } else {
                    collateral_value
                };
                
                // Now subtract the debt amount from adjusted collateral value
                adjusted_collateral_value - debt_to_liquidate
            } else {
                // For ICR > 100% + lp: penalty = lp*y
                (debt_to_liquidate * liquidation_penalty) / 10000
            };

            // let penalty_amount_in_collateral = fixed_point32::divide_u64(penalty_amount, price);
            let penalty_amount_in_collateral = if (collateral_decimals < debt_decimals) {
                fixed_point32::divide_u64(penalty_amount, price) / 
                math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
            } else if (collateral_decimals > debt_decimals) {
                fixed_point32::divide_u64(penalty_amount, price) * 
                math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
            } else {
                fixed_point32::divide_u64(penalty_amount, price)
            };

            let protocol_fee = (penalty_amount_in_collateral * liquidation_fee_protocol) / 10000;
            let liquidator_penalty = penalty_amount_in_collateral - protocol_fee;
            // let debt_in_collateral = fixed_point32::divide_u64(debt_to_liquidate, price);
            let debt_in_collateral = if (collateral_decimals < debt_decimals) {
                fixed_point32::divide_u64(debt_to_liquidate, price) / 
                math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
            } else if (collateral_decimals > debt_decimals) {
                fixed_point32::divide_u64(debt_to_liquidate, price) * 
                math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
            } else {
                fixed_point32::divide_u64(debt_to_liquidate, price)
            };

            let liquidator_reward = liquidator_penalty + debt_in_collateral;
            
            let refund = if (liquidator_reward + protocol_fee < collateral_to_liquidate) {
                collateral_to_liquidate - (liquidator_reward + protocol_fee)
            } else {
                0
            };
            
            (liquidator_reward, protocol_fee, refund)
        };

        let available_for_liquidator = collateral_to_liquidate - protocol_fee_in_collateral - user_refund;
        
        // Take minimum between calculated reward and available amount
        let liquidator_reward_in_collateral = if (liquidator_reward_in_collateral > available_for_liquidator) {
            available_for_liquidator
        } else {
            liquidator_reward_in_collateral
        };

        // Transfer and burn debtToken from liquidator
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let debtToken_coins = coin::withdraw<CASH>(liquidator, debt_to_liquidate);
        coin::burn(debtToken_coins, &vault_manager.debtToken_burn_cap);

        // Get resource signer for transfers
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);

        // Transfer protocol fee if any
        if (protocol_fee_in_collateral > 0) {
            coin::transfer<CoinType>(&resource_signer, config::get_fee_collector(), protocol_fee_in_collateral);
        };

        // Transfer reward to liquidator
        coin::transfer<CoinType>(&resource_signer, liquidator_addr, liquidator_reward_in_collateral);

        // Transfer refund to user if any
        if (user_refund > 0) {
            coin::transfer<CoinType>(&resource_signer, user_addr, user_refund);
        };

        // Calculate remaining collateral
        let remaining_collateral = collateral_amount - (liquidator_reward_in_collateral + protocol_fee_in_collateral + user_refund);

        // Update total stats
        let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
        let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
        *total_collateral = *total_collateral - (liquidator_reward_in_collateral + protocol_fee_in_collateral + user_refund);
        *total_debt = *total_debt - debt_to_liquidate;

        // Emit events
        events::emit_trove_liquidated(
            user_addr, 
            liquidator_addr,
            type_info::type_of<CoinType>(),
            collateral_amount,
            debt_to_liquidate,
            liquidator_reward_in_collateral,
            protocol_fee_in_collateral,
            user_refund,
            timestamp::now_seconds()
        );

        events::emit_trove_updated_event(
            user_addr,
            type_info::type_of<CoinType>(),
            remaining_collateral,
            remaining_debt,
            timestamp::now_seconds(),
            block::get_current_block_height(),
            events::trove_action_liquidate()
        );

        // Update position
        positions::update_position<CoinType>(
            user_addr,
            remaining_collateral,
            remaining_debt,
            timestamp::now_seconds()
        );
    }

    

    public entry fun redeem<CoinType>(
        redeemer: &signer,
        provider_addr: address,
        debtToken_amount: u64,
        min_collateral_out: u64
    ) acquires  TroveManager, SignerCapability, LRCollectorCapability {
        let collateral_type = type_info::type_of<CoinType>();
        
        // Verify redemption provider and position exists
        assert!(positions::is_redemption_provider<CoinType>(provider_addr), events::err_not_redemption_provider());
        positions::assert_position_exists<CoinType>(provider_addr);
        
        let (collateral_amount, debt_amount, _, _) = positions::get_position<CoinType>(provider_addr);
        let redemption_fee = config::get_redemption_fee<CoinType>();
        let redemption_fee_gratuity = config::get_redemption_fee_gratuity<CoinType>();
        let minimum_debt = config::get_minimum_debt<CoinType>();
        let liquidation_reserve = config::get_liquidation_reserve<CoinType>();

        // Get operation status
        let (_, _, _, redeem_enabled) = config::get_operation_status<CoinType>();
        // Calculate maximum redeemable amount
        let max_redeemable = debt_amount - liquidation_reserve;
        assert!(redeem_enabled, events::err_operation_disabled());

        let actual_redemption_amount = if (debtToken_amount >= max_redeemable) {
            max_redeemable
        } else {
            let remaining_debt = debt_amount - debtToken_amount;
            if (remaining_debt < minimum_debt + liquidation_reserve) {
                // Truncate redemption amount to maintain minimum debt
                debt_amount - (minimum_debt + liquidation_reserve)
            } else {    
                debtToken_amount
            }
        };

        // Calculate collateral amounts
        let price = enhanced_price_oracle::get_price<CoinType>();
        let collateral_decimals = config::get_collateral_decimals<CoinType>();
        let debt_decimals = 8;
        // let collateral_to_redeem = fixed_point32::divide_u64(actual_redemption_amount, price);
        let collateral_to_redeem = if (collateral_decimals < debt_decimals) {
            fixed_point32::divide_u64(actual_redemption_amount, price) / 
            math64::pow(10, ((debt_decimals - collateral_decimals) as u64))
        } else if (collateral_decimals > debt_decimals) {
            fixed_point32::divide_u64(actual_redemption_amount, price) * 
            math64::pow(10, ((collateral_decimals - debt_decimals) as u64))
        } else {
            fixed_point32::divide_u64(actual_redemption_amount, price)
        };
        let redemption_fee = (collateral_to_redeem * redemption_fee) / 10000;
        let user_gratuity_fee = (collateral_to_redeem * redemption_fee_gratuity) / 10000;

        assert!(redemption_fee > 0, events::err_fee_too_small());
        assert!(user_gratuity_fee > 0, events::err_fee_too_small());    

        let collateral_after_fee = collateral_to_redeem - redemption_fee - user_gratuity_fee;
        
        // Slippage protection check
        assert!(collateral_after_fee >= min_collateral_out, events::err_slippage_exceeded());

        // Verify balances
        assert!(collateral_amount >= collateral_to_redeem, events::err_insufficient_collateral_balance());

        // Handle debtToken transfer and burn
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let debtToken_coins = coin::withdraw<CASH>(redeemer, actual_redemption_amount);
        coin::burn(debtToken_coins, &vault_manager.debtToken_burn_cap);

        // Get resource signer for transfers
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);

        // Transfer collateral to redeemer
        coin::transfer<CoinType>(&resource_signer, signer::address_of(redeemer), collateral_after_fee);

        // Transfer fee to collector
        if (redemption_fee > 0) {
            coin::transfer<CoinType>(&resource_signer, config::get_fee_collector(), redemption_fee);
        };

        if (user_gratuity_fee > 0) {
            coin::transfer<CoinType>(&resource_signer, provider_addr, user_gratuity_fee);   
        };

        // Check if position is being closed
        let is_closing = actual_redemption_amount == max_redeemable;
        let new_collateral = collateral_amount - collateral_to_redeem ;
        let new_debt = debt_amount - actual_redemption_amount;


        let total_collateral = table::borrow_mut(&mut vault_manager.total_collateral, collateral_type);
        let total_debt = table::borrow_mut(&mut vault_manager.total_debt, collateral_type);
        if (is_closing) {
            // Burn liquidation reserve
            let lr_coins = coin::withdraw<CASH>(
                &account::create_signer_with_capability(&borrow_global<LRCollectorCapability>(@cdp).cap),
                liquidation_reserve
            );
            coin::burn(lr_coins, &vault_manager.debtToken_burn_cap);

            let excess_collateral = new_collateral;  // Track excess before modifying
            if (excess_collateral > 0) {
                coin::transfer<CoinType>(&resource_signer, provider_addr, excess_collateral);
                new_collateral = 0;
            };
            new_debt = 0;
            *total_debt = *total_debt - (actual_redemption_amount + liquidation_reserve);
            // Update total stats for closing position
            *total_collateral = *total_collateral - collateral_amount;  
        } else {
            *total_collateral = *total_collateral - collateral_to_redeem;
            *total_debt = *total_debt - actual_redemption_amount;
        };
        
       // if (is_closing) {
        //     *total_collateral = *total_collateral - new_collateral;
        // }; 

        events::emit_redemption_event(signer::address_of(redeemer), provider_addr, collateral_type, collateral_to_redeem, actual_redemption_amount, redemption_fee, timestamp::now_seconds());
        events::emit_trove_updated_event(provider_addr, collateral_type, new_collateral, new_debt, timestamp::now_seconds(), block::get_current_block_height(),events::trove_action_redeem());
        // Update or remove position
        if (new_collateral == 0 && new_debt == 0) {
            positions::remove_position<CoinType>(provider_addr);
        } else {
            positions::update_position<CoinType>(
                provider_addr,
                new_collateral,
                new_debt,
                timestamp::now_seconds()
            );
        };
    }

    public entry fun redeem_multiple<CoinType>(
        redeemer: &signer,
        providers: vector<address>,
        amounts: vector<u64>,
        min_collateral_outs: vector<u64>
    ) acquires TroveManager, SignerCapability, LRCollectorCapability {
        let i = 0;
        let len = vector::length(&providers);
        assert!(len == vector::length(&amounts), events::err_invalid_array_length());
        assert!(len == vector::length(&min_collateral_outs), events::err_invalid_array_length());

        while (i < len) {
            let provider = *vector::borrow(&providers, i);
            let amount = *vector::borrow(&amounts, i);
            let min_collateral_out = *vector::borrow(&min_collateral_outs, i);
            redeem<CoinType>(redeemer, provider, amount, min_collateral_out);
            i = i + 1;
        }
    }


    public entry fun set_config<CoinType>(
        admin: &signer,
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        redemption_fee: u64,
        enabled: bool,
        liquidation_fee_protocol: u64,
        redemption_fee_gratuity: u64
    ) {
        // Verify admin
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        //call config set_config
        config::set_config<CoinType>( minimum_debt, mcr, borrow_rate, liquidation_threshold, liquidation_penalty, redemption_fee, enabled, liquidation_fee_protocol, redemption_fee_gratuity);
        events::emit_collateral_config_updated_event(minimum_debt, mcr, borrow_rate, liquidation_threshold, liquidation_penalty, redemption_fee, enabled, liquidation_fee_protocol, redemption_fee_gratuity);
    }

    public entry fun set_oracle<CoinType>(
        admin: &signer,
        new_oracle_id: u32,
        new_price_age: u64
    ) {
        // Verify admin
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        enhanced_price_oracle::set_direct_usd_oracle<CoinType>(new_oracle_id, new_price_age);
        events::emit_oracle_updated_event(new_oracle_id, new_price_age);
    }

    public entry fun set_operation_status<CoinType>(
        admin: &signer,
        open_trove: bool,
        borrow: bool,
        deposit: bool,
        redeem: bool
    ) {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        
        config::set_operation_status<CoinType>( open_trove, borrow, deposit, redeem);
        events::emit_operation_status_updated_event( open_trove, borrow, deposit, redeem);
    }


    public entry fun set_fee_collector(
        admin: &signer,
        new_fee_collector: address
    ) {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        config::set_fee_collector(new_fee_collector);
        events::emit_fee_collector_updated_event(new_fee_collector);
    }

    public entry fun set_primary_rate_oracle<CoinType>(
        admin: &signer,
        rate_oracle_id: u32,
        base_usd_oracle_id: u32,
        price_age: u64
    ) {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        enhanced_price_oracle::set_primary_rate_oracle<CoinType>(rate_oracle_id, base_usd_oracle_id, price_age);
        events::emit_oracle_updated_event(rate_oracle_id, price_age);
    }

    public entry fun remove_enhanced_oracle<CoinType>(
        admin: &signer
    ) {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        enhanced_price_oracle::remove_enhanced_oracle<CoinType>();
    }


    // Helper functions
    public fun verify_collateral_ratio<CoinType>(
        collateral_amount: u64,
        debt_amount: u64
    ) {
        if (debt_amount > 0) {
            let mcr = config::get_mcr<CoinType>();
            let price = enhanced_price_oracle::get_price<CoinType>();
            let collateral_decimals = config::get_collateral_decimals<CoinType>();
            let debt_decimals = 8; // CASH decimals
            
            // Convert to u128 to avoid overflow in large calculations
            let collateral_amount_u128 = (collateral_amount as u128);
            let debt_amount_u128 = (debt_amount as u128);
            
            // Handle decimal normalization before price multiplication to reduce overflow risk
            if (collateral_decimals < debt_decimals) {
                // Scale up collateral amount to match debt precision
                let scale_factor = math64::pow(10, ((debt_decimals - collateral_decimals) as u64));
                collateral_amount_u128 = collateral_amount_u128 * (scale_factor as u128);
            } else if (collateral_decimals > debt_decimals) {
                // Scale down collateral amount to match debt precision
                let scale_factor = math64::pow(10, ((collateral_decimals - debt_decimals) as u64));
                collateral_amount_u128 = collateral_amount_u128 / (scale_factor as u128);
            };
            
            // Extract the raw price value as u128 from the FixedPoint32
            let price_value_u128 = (fixed_point32::get_raw_value(price) as u128);
            
            // Calculate collateral value directly in u128
            // fixed_point32 raw value is scaled by 2^32, so we need to divide by 2^32
            let collateral_value_u128 = (collateral_amount_u128 * price_value_u128) >> 32;
            
            // Calculate ratio: (collateral_value * 10000) / debt
            let ratio_u128 = (collateral_value_u128 * 10000) / debt_amount_u128;
            
            // Convert back to u64 for the final comparison (safe because MCR is a small value)
            let ratio = (ratio_u128 as u64);
            
            assert!(ratio >= mcr, events::err_insufficient_collateral());
        }
    }



    fun assert_trove_active<CoinType>(user_addr: address){
        let (_, debt_amount, _, _) = positions::get_position<CoinType>(user_addr);
        assert!(debt_amount > 0, events::err_no_position_exists());
    }   



    // This function should be test-only for mainnet deployment
    // Price updates should come from oracle feeds in production
    #[test_only]
    public entry fun set_price<CoinType>(
        admin: &signer,
        price: u64
    )   {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        price_oracle::set_price<CoinType>(price);
    }



    #[view]
    public fun get_lr_collector(): address acquires LRCollectorCapability {
        let lr_collector_cap = &borrow_global<LRCollectorCapability>(@cdp).cap;
        let lr_collector_signer = account::create_signer_with_capability(lr_collector_cap);
        signer::address_of(&lr_collector_signer)
    }

    // View functions
    #[view]
    public fun get_user_position<CoinType>(user_addr: address): (u64, u64, bool)  {
        let (collateral_amount, debt_amount, _, _) = positions::get_position<CoinType>(user_addr);
        (collateral_amount, debt_amount, debt_amount > 0)
    }

    #[view]
    public fun get_collateral_config<CoinType>(): (u64, u64, u64, u64, u64, u64, u64, bool, u64, u64)   {
        config::get_config<CoinType>()
    }

    public fun get_collateral_price<CoinType>(): FixedPoint32 {
        enhanced_price_oracle::get_price<CoinType>()
    }

    #[view]
    public fun get_collateral_price_raw<CoinType>(): u64  {
        enhanced_price_oracle::get_price_raw<CoinType>()
    }

    #[view]
    public fun get_total_stats<CoinType>(): (u64, u64) acquires TroveManager {
        let vault_manager = borrow_global<TroveManager>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        
        let total_collateral = if (table::contains(&vault_manager.total_collateral, collateral_type)) {
            *table::borrow(&vault_manager.total_collateral, collateral_type)
        } else {
            0
        };
        
        let total_debt = if (table::contains(&vault_manager.total_debt, collateral_type)) {
            *table::borrow(&vault_manager.total_debt, collateral_type)
        } else {
            0
        };
        
        (total_collateral, total_debt)
    }

    #[view]
    public fun is_redemption_provider<CoinType>(user_addr: address): bool  {
        positions::is_redemption_provider<CoinType>(user_addr)
    }

    #[view]
    public fun get_fee_collector(): address {
        config::get_fee_collector()
    }

    #[view]
    public fun is_valid_collateral<CoinType>(): bool  {
        config::is_valid_collateral<CoinType>()
    }

    #[view]
    public fun get_operation_status<CoinType>(): (bool, bool, bool, bool) {
        config::get_operation_status<CoinType>()
    }

    #[test_only]
    public fun mint_debtToken_for_test(addr: address, amount: u64) acquires TroveManager {
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let debtToken_coins = coin::mint(amount, &vault_manager.debtToken_mint_cap);
        coin::deposit(addr, debtToken_coins);
    }


}