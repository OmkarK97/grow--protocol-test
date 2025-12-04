script {
    use std::signer;
    use std::option;
    use std::vector;
    use supra_framework::coin;
    use atmos_aggregator::atmos_agg_swap;


    // Vault modules by full address (your deployed addr)
    use vault::vault_core;
    use vault::strategy_core;

    // NO Atmos use direct full-path call

    fun main
        <
            CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
            Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
            Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
            Coin30, AssetType
        >(
        fund_manager: &signer,
        user_addr: address,
        // Exact Atmos params (from your shared code)
        _swap_mode: u64,
        _split_count: u8,
        _step_counts: vector<u8>,
        _dex_types: vector<vector<vector<u8>>>,
        _pool_ids: vector<vector<vector<u64>>>,
        _is_x_to_y: vector<vector<vector<bool>>>,
        _pool_types: vector<vector<u8>>,
        _token_addresses: vector<vector<vector<address>>>,
        _token_x_addresses: vector<vector<address>>,
        _token_y_addresses: vector<vector<address>>,
        _extra_data: option::Option<vector<vector<vector<vector<vector<u8>>>>>>,
        _step_amounts: vector<vector<vector<u64>>>,
        _extra_dex_types: option::Option<vector<vector<vector<u8>>>>,
        _output_token_address: address,
        _split_amounts: vector<u64>,
        _min_output_amount: u64,
        _fee_basis_points: u64,
        _integrator_address: address
    ) {
        let fund_addr = signer::address_of(fund_manager);

        // 1. Trigger harvest: Liquidate CDP Transfer collateral to fund_addr
        vault_core::harvest_aggregator<
            CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
            Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
            Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
            Coin30, AssetType
        >(
            fund_manager, 
            user_addr
        );
        
        // 2. Direct Atmos swap (input from fund_addr balance; output to fund_addr)
        atmos_agg_swap::aggragated_swap_entry<
            CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
            Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
            Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
            Coin30, AssetType
        >(
            fund_manager,  // _user_signer
            fund_addr,     // _recipient_address
            _swap_mode,
            _split_count,
            _step_counts,
            _dex_types,
            _pool_ids,
            _is_x_to_y,
            _pool_types,
            _token_addresses,
            _token_x_addresses,
            _token_y_addresses,
            _extra_data,
            _step_amounts,
            _extra_dex_types,
            _output_token_address,
            _split_amounts,
            _min_output_amount,
            _fee_basis_points,
            _integrator_address
        );

        // 3. Transfer swapped output back to vault resource
        let vault_resource_addr = vault_core::get_vault_resource_address();
        let output_balance = coin::balance<AssetType>(fund_addr);
        if (output_balance > 0) {
            let output_coins = coin::withdraw<AssetType>(fund_manager, output_balance);
            coin::deposit(vault_resource_addr, output_coins);
        };

        // 4. Sync: Calc yield, apply perf fee (if positive), emit events
        vault_core::sync_assets<AssetType>(fund_manager);
    }
}