module vault::strategy_core {
    use std::signer;
    use aptos_std::type_info::{TypeInfo, type_of};
    use supra_framework::coin;
    use supra_framework::account;
    use std::vector;
    use std::option;
    use cdp::cdp_multi;
    use dexlyn_swap::router;
    use dexlyn_swap::curves::Uncorrelated;
    use supra_framework::fungible_asset;

    friend vault::vault_core;

    // Keep StrategyInfo focused on core functionality
    struct StrategyInfo has key {
        vault_resource_addr: address,
        asset_type: TypeInfo

    }

    // Separate struct for CDP configuration
    struct CDPConfig has key {
        slippage: u64  // 1000 = 10%
    }

    const SLIPPAGE_PRECISION: u64 = 10000; // Base 10000 for percentage calculation

    // Error codes
    const ERR_NOT_STRATEGY_OWNER: u64 = 1;
    const ERR_ALREADY_SETUP: u64 = 2;
    const ERR_NOT_SETUP: u64 = 3;
    const ERR_INVALID_SLIPPAGE: u64 = 4;
    const MAX_SLIPPAGE: u64 = 5000; // 50% max slippage

    const PRICE_PRECISION: u64 = 100000000; // 10^8 for price precision

    /// Stores the resource account capability
    struct StrategyCapability has key {
        cap: account::SignerCapability
    }

    public entry fun setup(
        strategy_owner: &signer,
        slippage: u64    // New parameter: 1000 = 10%
    ) {
        // Check if caller is strategy owner
        assert!(signer::address_of(strategy_owner) == @vault, ERR_NOT_STRATEGY_OWNER);
        
        // Ensure strategy hasn't been setup already
        assert!(!exists<CDPConfig>(@vault), ERR_ALREADY_SETUP);
        
        // Create and store CDP configuration with slippage
        move_to(strategy_owner, CDPConfig {
            slippage
        });
    }


    public fun initialize<AssetType>(
        strategy_owner: &signer,
        vault_resource_addr: address
    ) {
        let _owner_addr = signer::address_of(strategy_owner);
        
        move_to(strategy_owner, StrategyInfo {
            vault_resource_addr,
            asset_type: type_of<AssetType>(),
        });

        // Create resource account for strategy
        let (strategy_signer, strategy_cap) = account::create_resource_account(strategy_owner, b"strategy_pool");
        let strategy_addr = signer::address_of(&strategy_signer);

        // Store strategy capability
        move_to(strategy_owner, StrategyCapability {
            cap: strategy_cap
        });

        // Register strategy account for asset type
        if (!coin::is_account_registered<AssetType>(strategy_addr)) {
            coin::register<AssetType>(&strategy_signer);
        };
    }


    #[view]
    public fun balance_of<AssetType>(): u64 acquires StrategyCapability {
        // Only return strategy's balance, not vault's
        let strategy_signer = get_strategy_signer();
        let strategy_addr = signer::address_of(&strategy_signer);
        coin::balance<AssetType>(strategy_addr)
    }


    // Helper function to get strategy signer
    public(friend)  fun get_strategy_signer(): signer acquires StrategyCapability {
        account::create_signer_with_capability(&borrow_global<StrategyCapability>(@vault).cap)
    }



    public(friend) fun execute_liquidate<
        AssetType, 
        CollateralType
    >(
        user_addr: address
    ) acquires StrategyInfo, StrategyCapability, CDPConfig {
        // Check if caller is strategy owner
        let _owner = borrow_global<StrategyInfo>(@vault);

        // Assert that CDPConfig exists and is set
        assert!(exists<CDPConfig>(@vault), ERR_NOT_SETUP);

        let strategy_signer = get_strategy_signer();
        let strategy_addr = signer::address_of(&strategy_signer);

        if (!coin::is_account_registered<CollateralType>(strategy_addr)) {
            coin::register<CollateralType>(&strategy_signer);
        };
        
        cdp_multi::liquidate<CollateralType>(
            &strategy_signer,
            user_addr
        );
        
        let collateral_balance = coin::balance<CollateralType>(strategy_addr);   
        let price = cdp_multi::get_collateral_price_raw<CollateralType>();
        let collateral_value = collateral_balance * price / PRICE_PRECISION;
        
        // Apply slippage to collateral value
        let cdp_config = borrow_global<CDPConfig>(@vault);
        let min_amount_out = collateral_value - collateral_value * cdp_config.slippage / SLIPPAGE_PRECISION;
        
        if (collateral_balance > 0) {
            let coins_to_swap = coin::withdraw<CollateralType>(&strategy_signer, collateral_balance);
            
            let swapped_asset = router::swap_exact_coin_for_coin<
                CollateralType, AssetType, Uncorrelated
            >(
                coins_to_swap,
                min_amount_out
            );

            // Get the vault resource address
            let strategy = borrow_global<StrategyInfo>(@vault);
            let vault_resource_addr = strategy.vault_resource_addr;
            // Transfer the swapped assets to the vault resource account
            coin::deposit(vault_resource_addr, swapped_asset);

            // Transfer any remaining AssetType balance from strategy resource account to vault
            let remaining_asset_balance = coin::balance<AssetType>(strategy_addr);
            if (remaining_asset_balance > 0) {
                let remaining_assets = coin::withdraw<AssetType>(&strategy_signer, remaining_asset_balance);
                coin::deposit(vault_resource_addr, remaining_assets);
            };
        };
    }

    // public(friend) fun execute_liquidate_aggregator<
    //     CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
    //     Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
    //     Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
    //     Coin30, AssetType
    // >(
    //     // These input parameters should be consumed/destroyed if passed in
    //     _swap_mode: u64,
    //     _split_count: u8,
    //     _step_counts: vector<u8>,
    //     _dex_types: vector<vector<vector<u8>>>,
    //     _pool_ids: vector<vector<vector<u64>>>,
    //     _is_x_to_y: vector<vector<vector<bool>>>,
    //     _pool_types: vector<vector<u8>>,
    //     _token_addresses: vector<vector<vector<address>>>,
    //     _token_x_addresses: vector<vector<address>>,
    //     _token_y_addresses: vector<vector<address>>,
    //     _extra_data: option::Option<vector<vector<vector<vector<vector<u8>>>>>>,
    //     _step_amounts: vector<vector<vector<u64>>>,
    //     _extra_dex_types: option::Option<vector<vector<vector<u8>>>>,
    //     _output_token_address: address,
    //     _split_amounts: vector<u64>,
    //     _min_output_amount: u64,
    //     _fee_basis_points: u64,
    //     _integrator_address: address,
    //     user_addr: address
    // )acquires StrategyInfo, StrategyCapability{
    //     // Check if caller is strategy owner
    //     let _owner = borrow_global<StrategyInfo>(@vault);

    //     let strategy_signer = get_strategy_signer();
    //     let strategy_addr = signer::address_of(&strategy_signer);

    //     if (!coin::is_account_registered<CollateralType>(strategy_addr)) {
    //         coin::register<CollateralType>(&strategy_signer);
    //     };
        
    //     // Liquidate the position
    //     cdp_multi::liquidate<CollateralType>(
    //         &strategy_signer,
    //         user_addr
    //     );
        
    //     let collateral_balance = coin::balance<CollateralType>(strategy_addr);   
    //     let price = cdp_multi::get_collateral_price_raw<CollateralType>();
    //     let collateral_value = collateral_balance * price / PRICE_PRECISION;
        
        
    //     if (collateral_balance > 0) {
            
    //         // Execute the swap - backend passes input via parameters
           
    //         atmos_agg_swap::aggragated_swap_entry<
    //             CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
    //             Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
    //             Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
    //             Coin30, AssetType
    //         >(
    //             &strategy_signer, 
    //             strategy_addr,
    //             _swap_mode,
    //             _split_count,
    //             _step_counts,
    //             _dex_types,
    //             _pool_ids,
    //             _is_x_to_y,
    //             _pool_types,
    //             _token_addresses,
    //             _token_x_addresses,
    //             _token_y_addresses,
    //             _extra_data,
    //             _step_amounts,
    //             _extra_dex_types,
    //             _output_token_address,
    //             _split_amounts,
    //             _min_output_amount,
    //             _fee_basis_points,
    //             _integrator_address
    //         );

    //         // Get the vault resource address
    //         let strategy = borrow_global<StrategyInfo>(@vault);
    //         let vault_resource_addr = strategy.vault_resource_addr;


    //         // Transfer any remaining AssetType balance from strategy resource account to vault
    //         let remaining_asset_balance = coin::balance<AssetType>(strategy_addr);
    //         if (remaining_asset_balance > 0) {
    //             let remaining_assets = coin::withdraw<AssetType>(&strategy_signer, remaining_asset_balance);
    //             coin::deposit(vault_resource_addr, remaining_assets);
    //         };
    //     };
    // }

    public(friend) fun execute_liquidate_aggregator<
        CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
        Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
        Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
        Coin30, AssetType
    >(
       fund_manager_addr: address,
       user_addr: address,
    )acquires StrategyInfo, StrategyCapability{
        // Check if caller is strategy owner
        let _owner = borrow_global<StrategyInfo>(@vault);

        let strategy_signer = get_strategy_signer();
        let strategy_addr = signer::address_of(&strategy_signer);

        if (!coin::is_account_registered<CollateralType>(strategy_addr)) {
            coin::register<CollateralType>(&strategy_signer);
        };
        
        // Liquidate the position
        // cdp_multi::liquidate<CollateralType>(
        //     &strategy_signer,
        //     user_addr
        // );
        
        let collateral_balance = coin::balance<CollateralType>(strategy_addr);   
        // let price = cdp_multi::get_collateral_price_raw<CollateralType>();
        // let collateral_value = collateral_balance * price / PRICE_PRECISION;
        
        
        if (collateral_balance > 0) {

            let coins_to_transfer = coin::withdraw<CollateralType>(&strategy_signer, collateral_balance);
            coin::deposit(fund_manager_addr, coins_to_transfer);  // Now at fund_manager

        };
    }


    

    public entry fun update_slippage(
        strategy_owner: &signer,
        new_slippage: u64
    ) acquires CDPConfig {
        // Check if caller is strategy owner
        assert!(signer::address_of(strategy_owner) == @vault, ERR_NOT_STRATEGY_OWNER);
        
        // Assert that CDPConfig exists
        assert!(exists<CDPConfig>(@vault), ERR_NOT_SETUP);
        
        // Validate new slippage value (must be <= 50%)
        assert!(new_slippage <= MAX_SLIPPAGE, ERR_INVALID_SLIPPAGE);
        
        // Update slippage
        let config = borrow_global_mut<CDPConfig>(@vault);
        config.slippage = new_slippage;
    }

    /// Get the current slippage value
    /// Returns slippage in basis points (e.g., 1000 = 10%)
    #[view]
    public fun get_slippage(): u64 acquires CDPConfig {
        assert!(exists<CDPConfig>(@vault), ERR_NOT_SETUP);
        borrow_global<CDPConfig>(@vault).slippage
    }

    #[view]
    public fun get_strategy_resource_address(): address acquires StrategyCapability {
        let strategy_signer = get_strategy_signer();
        signer::address_of(&strategy_signer)
    }
}