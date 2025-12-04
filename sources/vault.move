module vault::vault_core {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info::{type_of, TypeInfo};
    use supra_framework::coin::{Self, MintCapability, BurnCapability};
    use supra_framework::account;
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::block;
    use std::option;
    use vault::strategy_core;
    use supra_framework::fungible_asset;

    /// Withdrawal request tracking
    struct WithdrawRequest has store, drop {
        assets: u64,          
        request_time: u64,
        processed: bool,
        request_id: u64  ,
        delay_at_request: u64
    }

    // Add a new struct to store all requests for a user (without drop ability)
    struct UserWithdrawRequests has key, store {
        requests: Table<u64, WithdrawRequest>,  // request_id -> WithdrawRequest
        request_ids: vector<u64>,               // List of request IDs for iteration
        next_request_id: u64,
        total_pending_assets: u64
    }

    struct DelayedWithdrawalCapability has key {
        cap: account::SignerCapability
    }

     /// Extended vault configuration
    struct VaultInfo has key {
        name: String,
        symbol: String,
        decimals: u8,
        total_assets: u64,
        total_shares: u64,
        paused: bool,
        withdraw_requests: Table<address, UserWithdrawRequests>,
        tvl_limit: u64,
        performance_fee: u64,
        withdraw_delay: u64,
        asset_type: TypeInfo,
        fee_recipient: address,
        withdrawal_fee: u64,  
        min_withdrawal_amount: u64,
    }

    /// Resource account capability
    struct VaultCapability has key {
        cap: account::SignerCapability
    }

    /// Stores mint/burn capabilities for the vault share token
    struct ShareTokenCapability has key {
        mint_cap: MintCapability<VaultShare>,
        burn_cap: BurnCapability<VaultShare>
    }

    /// The vault share token type
    struct VaultShare has key { }


    struct FundManagerInfo has key {
        fund_manager: address,
    }

     /// Events
    #[event]
    struct DepositEvent has drop, store {
        depositor: address,
        receiver: address,
        assets: u64,
        shares: u64,
        timestamp: u64,
        block_height: u64
    }

    #[event]
    struct WithdrawEvent has drop, store {
        withdrawer: address,
        receiver: address,
        owner: address,
        assets: u64,
        shares: u64,
        timestamp: u64,
        block_height: u64
    }


    #[event]
    struct InitializeEvent has drop, store {
        vault_address: address,
        asset_type: TypeInfo,
        name: String,
        symbol: String
    }

    #[event]
    struct PausedEvent has drop, store { }
    
    #[event]
    struct UnpausedEvent has drop, store {}

    #[event]
    struct WithdrawRequestEvent has drop, store {
        user: address,
        assets: u64,
        request_time: u64,
        timestamp: u64,
        block_height: u64
    }
    
    #[event]
    struct YieldGeneratedEvent has drop, store {
        yield_amount: u64,
        fee_amount: u64,
        remaining_yield: u64,
        fee_recipient: address
    }

    #[event]
    struct PerformanceFeeUpdatedEvent has drop, store {
        old_fee: u64,
        new_fee: u64
    }

    #[event]
    struct FeeRecipientUpdatedEvent has drop, store {
        old_recipient: address,
        new_recipient: address
    }

    #[event]
    struct TvlLimitUpdatedEvent has drop, store {
        old_limit: u64,
        new_limit: u64
    }

    #[event]
    struct WithdrawDelayUpdatedEvent has drop, store {
        old_delay: u64,
        new_delay: u64
    }

    #[event]
    struct WithdrawalFeeUpdatedEvent has drop, store {
        old_fee: u64,
        new_fee: u64
    }

    #[event]
    struct WithdrawalFeeCollectedEvent has drop, store {
        user: address,
        fee_amount: u64,
        withdrawal_amount: u64,
        fee_recipient: address
    }

    // Add a new event for tracking min withdrawal amount updates
    #[event]
    struct MinWithdrawalAmountUpdatedEvent has drop, store {
        old_amount: u64,
        new_amount: u64
    }

    // Add this event
    #[event]
    struct AssetsSyncedEvent has drop, store {
        old_total: u64,
        new_total: u64,
        difference: u64
    }

    #[event]
    struct FundManagerUpdatedEvent has drop, store {
        old_manager: address,
        new_manager: address
    }

    const PRECISION: u64 = 1000000; // 6 decimals for share calculation
    const FEE_PRECISION: u64 = 100000;
    const MAX_U64: u64 = 18446744073709551615;

    // Error codes
    const ERR_ALREADY_INITIALIZED: u64 = 1;
    const ERR_ZERO_DEPOSIT: u64 = 2;
    const ERR_VAULT_PAUSED: u64 = 3;
    const ERR_NOT_ADMIN: u64 = 4;
    const ERR_INSUFFICIENT_SHARES: u64 = 5;
    const ERR_INVALID_ASSET_TYPE: u64 = 6;
    const ERR_NOT_AUTHORIZED: u64 = 7;
    const ERR_MATH_OVERFLOW: u64 = 8;
    const ERR_TVL_LIMIT_EXCEEDED: u64 = 9;
    const ERR_EXCESSIVE_SLIPPAGE: u64 = 10;
    const ERR_WITHDRAWAL_TOO_SMALL: u64 = 11;
    const ERR_NOT_FUND_MANAGER: u64 = 12;


    /// Stores the freeze capability
    struct FreezeCapabilityStore has key {
        cap: coin::FreezeCapability<VaultShare>
    }

    public entry fun initialize<AssetType>(
        admin: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        fee_recipient: address,
        initial_deposit: u64
    ) acquires ShareTokenCapability{
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @vault, ERR_NOT_ADMIN);
        assert!(!exists<VaultInfo>(admin_addr), ERR_ALREADY_INITIALIZED);
        assert!(initial_deposit > 0, ERR_ZERO_DEPOSIT);

         // Initialize share token
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<VaultShare>(
            admin,
            name,
            symbol,
            decimals,
            true
        );

        // Store freeze capability
        move_to(admin, FreezeCapabilityStore { cap: freeze_cap });

        // Store mint/burn capabilities - must be done before using mint_cap
        move_to(admin, ShareTokenCapability {
            mint_cap,
            burn_cap
        });

        // Create resource accounts
        let (vault_signer, vault_cap) = account::create_resource_account(admin, b"vault_pool");
        let vault_addr = signer::address_of(&vault_signer);
        let (delayed_withdrawal_signer, delayed_withdrawal_cap) = 
            account::create_resource_account(admin, b"delayed_withdrawals");

        // Register accounts for assets
        if (!coin::is_account_registered<AssetType>(vault_addr)) {
            coin::register<AssetType>(&vault_signer);
        };
        if (!coin::is_account_registered<AssetType>(signer::address_of(&delayed_withdrawal_signer))) {
            coin::register<AssetType>(&delayed_withdrawal_signer);
        };

        // Register admin for VaultShare if needed
        if (!coin::is_account_registered<VaultShare>(admin_addr)) {
            coin::register<VaultShare>(admin);
        };

        // Get the stored mint capability to use
        let share_cap = borrow_global<ShareTokenCapability>(admin_addr);
        
        // Mint initial shares to admin
        let share_tokens = coin::mint(initial_deposit, &share_cap.mint_cap);
        coin::deposit<VaultShare>(admin_addr, share_tokens);

        // Transfer initial deposit to vault
        coin::transfer<AssetType>(admin, vault_addr, initial_deposit);


        // Initialize vault storage with min_withdrawal_amount
        move_to(admin, VaultInfo {
            name,
            symbol,
            decimals,
            total_assets: initial_deposit,
            total_shares: initial_deposit,
            paused: false,
            withdraw_requests: table::new(),
            tvl_limit: 0,
            performance_fee: 0,
            withdraw_delay: 0,
            asset_type: type_of<AssetType>(),
            fee_recipient,
            withdrawal_fee: 0,
            // min_withdrawal_amount: 100000,  // Default: 100,000 units
            min_withdrawal_amount: 1000,  // Default: 100,000 units
        });

        // Store capabilities
        move_to(admin, VaultCapability { cap: vault_cap });
        move_to(admin, DelayedWithdrawalCapability { cap: delayed_withdrawal_cap });

        // Initialize strategy
        strategy_core::initialize<AssetType>(admin, vault_addr);
        // earn<AssetType>();

        // Emit initialization event
        event::emit(InitializeEvent {
            vault_address: vault_addr,
            asset_type: type_of<AssetType>(),
            name,
            symbol
        });
    }


    public entry fun deposit<AssetType>(
        user: &signer,
        assets: u64
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability {
        deposit_internal<AssetType>(user, assets, signer::address_of(user), 0);
    }

    public entry fun deposit_for<AssetType>(
        user: &signer,
        assets: u64,
        receiver: address
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability {
        deposit_internal<AssetType>(user, assets, receiver, 0);
    }

    public entry fun deposit_with_slippage<AssetType>(
        user: &signer,
        assets: u64,
        min_shares: u64
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability {
        deposit_internal<AssetType>(user, assets, signer::address_of(user), min_shares);
    }


    fun deposit_internal<AssetType>(
        user: &signer,
        assets: u64,
        receiver: address,
        min_shares: u64
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability  {
        let user_addr = signer::address_of(user);
        
        // Validate deposit
        assert!(assets > 0, ERR_ZERO_DEPOSIT);
        assert!(assets <= max_deposit<AssetType>(user_addr), ERR_TVL_LIMIT_EXCEEDED);
        
        let vault = borrow_global_mut<VaultInfo>(@vault);
        assert!(!vault.paused, ERR_VAULT_PAUSED);

        // Assert that AssetType matches the vault's asset type
        assert!(type_of<AssetType>() == vault.asset_type, ERR_INVALID_ASSET_TYPE);

        let shares = convert_to_shares<AssetType>(assets);
        if (min_shares > 0) {
            assert!(shares >= min_shares, ERR_EXCESSIVE_SLIPPAGE);
        };

        // Register user for VaultShare if needed
        if (!coin::is_account_registered<VaultShare>(user_addr)) {
            coin::register<VaultShare>(user);
        };
        
        // Transfer assets to vault
        let vault_signer = get_vault_signer();
        let vault_resource_addr = signer::address_of(&vault_signer);
        coin::transfer<AssetType>(user, vault_resource_addr, assets);

        // Deploy to strategy
        // earn<AssetType>();

        // Mint share tokens to user
        let share_cap = borrow_global<ShareTokenCapability>(@vault);
        let share_tokens = coin::mint(shares, &share_cap.mint_cap);
        coin::deposit<VaultShare>(receiver, share_tokens);

        // Update vault accounting
        let vault = borrow_global_mut<VaultInfo>(@vault);
        vault.total_assets = vault.total_assets + assets;
        vault.total_shares = vault.total_shares + shares;

        // Emit deposit event
        event::emit(DepositEvent {
            depositor: user_addr,
            receiver,
            assets,
            shares,
            timestamp: timestamp::now_seconds(),
            block_height: block::get_current_block_height()
        });
    }


    // fun earn<AssetType>() acquires VaultCapability {
    //     // Get vault signer and strategy address
    //     let vault_signer = get_vault_signer();
    //     let vault_addr = signer::address_of(&vault_signer);
        
    //     // Get strategy address
    //     let strategy_signer = strategy_core::get_strategy_signer();
    //     let strategy_addr = signer::address_of(&strategy_signer);
        
    //     // Get current balance in vault's resource account
    //     let available_assets = coin::balance<AssetType>(vault_addr);
        

    //     // if (available_assets > 0) {
    //     //     // First transfer assets to strategy's resource account
    //     //     coin::transfer<AssetType>(
    //     //         &vault_signer,
    //     //         strategy_addr,
    //     //         available_assets
    //     //     );
            
    //     //     // Then call strategy deposit to update accounting 
    //     //     strategy_core::deposit<AssetType>();
    //     // };
    // }


    public entry fun withdraw<AssetType>(
        user: &signer,
        assets: u64
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability, DelayedWithdrawalCapability {
        withdraw_internal<AssetType>(
            user,
            assets,
            signer::address_of(user),
            signer::address_of(user)
        );
    }

    public entry fun withdraw_to<AssetType>(
        user: &signer,
        assets: u64,
        receiver: address
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability, DelayedWithdrawalCapability {
        withdraw_internal<AssetType>(
            user,
            assets,
            receiver,
            signer::address_of(user)
        );
    }

    fun withdraw_internal<AssetType>(
        user: &signer,
        assets: u64,
        receiver: address,
        owner: address
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability, DelayedWithdrawalCapability {
        let user_addr = signer::address_of(user);
        assert!(user_addr == owner, ERR_NOT_AUTHORIZED);
        
        // Get necessary information in a scope that will be closed
        let delay: u64;
        let matches_asset_type: bool;
        let is_paused: bool;
        let withdrawal_fee: u64;
        let min_withdrawal_amount: u64;
        {
            let vault = borrow_global<VaultInfo>(@vault);
            is_paused = vault.paused;
            matches_asset_type = type_of<AssetType>() == vault.asset_type;
            delay = vault.withdraw_delay;
            withdrawal_fee = vault.withdrawal_fee;
            min_withdrawal_amount = vault.min_withdrawal_amount;
        }; // Scope ends, borrow released
        
        // Check assertions
        assert!(!is_paused, ERR_VAULT_PAUSED);
        assert!(matches_asset_type, ERR_INVALID_ASSET_TYPE);

        if (withdrawal_fee > 0) {
            assert!(assets >= min_withdrawal_amount, ERR_WITHDRAWAL_TOO_SMALL);
        };

        // Calculate and burn shares immediately regardless of delay
        let shares_to_burn = preview_withdraw<AssetType>(assets);
        let user_share_balance = coin::balance<VaultShare>(user_addr);
        assert!(shares_to_burn <= user_share_balance, ERR_INSUFFICIENT_SHARES);
        
        // Burn shares immediately in all cases
        let share_cap = borrow_global<ShareTokenCapability>(@vault);
        let share_tokens = coin::withdraw<VaultShare>(user, shares_to_burn);
        coin::burn(share_tokens, &share_cap.burn_cap);
        
        // Update vault accounting
        let vault = borrow_global_mut<VaultInfo>(@vault);
        vault.total_shares = vault.total_shares - shares_to_burn;
        vault.total_assets = vault.total_assets - assets;
            
        // If no delay, process immediately
        if (delay == 0) {
             // Process withdrawal immediately
            // let withdrawal_fee = vault.withdrawal_fee;
            let fee_recipient = vault.fee_recipient;
            process_withdrawal<AssetType>(user, receiver, assets, shares_to_burn, false, withdrawal_fee, fee_recipient);
            
            // Emit withdrawal event
            event::emit(WithdrawEvent {
                withdrawer: user_addr,
                receiver,
                owner,
                assets,
                shares: shares_to_burn,
                timestamp: timestamp::now_seconds(),
                block_height: block::get_current_block_height()
            });
        } else {
            // Create withdrawal request
            let vault_signer = get_vault_signer();
            let delayed_withdrawal_signer = get_delayed_withdrawal_signer();
            
            // Process withdrawal to delayed withdrawal account
            let withdrawal_fee = vault.withdrawal_fee;
            let fee_recipient = vault.fee_recipient;
            process_withdrawal<AssetType>(
                &vault_signer, 
                signer::address_of(&delayed_withdrawal_signer),
                assets,
                shares_to_burn,
                true,
                withdrawal_fee,
                fee_recipient
            );
          
            let request_time = timestamp::now_seconds();
            
            // Initialize user's withdraw requests if not exists
            if (!table::contains(&vault.withdraw_requests, user_addr)) {
                table::add(&mut vault.withdraw_requests, user_addr, UserWithdrawRequests {
                    requests: table::new(),
                    request_ids: vector::empty(),
                    next_request_id: 0,
                    total_pending_assets: 0
                });
            };

            // Add new request rather than replacing old one
            let user_requests = table::borrow_mut(&mut vault.withdraw_requests, user_addr);
            let request_id = user_requests.next_request_id;
            user_requests.next_request_id = request_id + 1;
            user_requests.total_pending_assets = user_requests.total_pending_assets + assets;

            // Add request ID to the vector for tracking
            vector::push_back(&mut user_requests.request_ids, request_id);
            let request_delay = vault.withdraw_delay;
            table::add(&mut user_requests.requests, request_id, WithdrawRequest {
                assets,
                request_time,
                processed: false,
                request_id,
                delay_at_request: request_delay
            });

            // Emit withdrawal request event
            event::emit(WithdrawRequestEvent {
                user: user_addr,
                assets,              
                request_time: request_time,
                timestamp: timestamp::now_seconds(),
                block_height: block::get_current_block_height()
            });
        }
    }

    public entry fun claim_withdrawal<AssetType>(
        user: &signer,
        receiver: address
    ) acquires VaultInfo, DelayedWithdrawalCapability {
        let user_addr = signer::address_of(user);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        assert!(table::contains(&vault.withdraw_requests, user_addr), ERR_NOT_AUTHORIZED);
        
        let user_requests = table::borrow_mut(&mut vault.withdraw_requests, user_addr);
        let current_time = timestamp::now_seconds();
        let delay = vault.withdraw_delay;
        let total_claimable = 0;
        
        // Get withdrawal fee and fee recipient
        let withdrawal_fee = vault.withdrawal_fee;
        let fee_recipient = vault.fee_recipient;
        
        // Iterate using the request_ids vector
        let i = 0;
        let request_ids_len = vector::length(&user_requests.request_ids);
        
        while (i < request_ids_len) {
            let request_id = *vector::borrow(&user_requests.request_ids, i);
            if (table::contains(&user_requests.requests, request_id)) {
                let request = table::borrow_mut(&mut user_requests.requests, request_id);
                if (!request.processed && current_time >= request.request_time + request.delay_at_request) {
                    total_claimable = total_claimable + request.assets;
                    request.processed = true;
                };
            };
            i = i + 1;
        };
        
        if (total_claimable > 0) {
            // Calculate fee
            let fee_amount = if (withdrawal_fee > 0) {
                let fee_u128 = (total_claimable as u128) * (withdrawal_fee as u128) / (FEE_PRECISION as u128);
                (fee_u128 as u64)
            } else {
                0
            };
            
            // Calculate net withdrawal amount after fee
            let withdrawal_amount = total_claimable - fee_amount;
        
        // Transfer assets from delayed withdrawal account to receiver
        let delayed_withdrawal_signer = get_delayed_withdrawal_signer();
        
        // Register receiver if needed
        if (!coin::is_account_registered<AssetType>(receiver)) {
            if (receiver == user_addr) {
                coin::register<AssetType>(user);
            } else {
                assert!(false, ERR_NOT_AUTHORIZED);
            };
        };
        
            // Transfer the withdrawal amount (after fee) to the receiver
        coin::transfer<AssetType>(
            &delayed_withdrawal_signer,
            receiver,
                withdrawal_amount
            );
            
            // Transfer fee to fee recipient if non-zero
            if (fee_amount > 0) {
                // Ensure fee recipient is registered for this asset type
                if (coin::is_account_registered<AssetType>(fee_recipient)) {
                    coin::transfer<AssetType>(
                        &delayed_withdrawal_signer,
                        fee_recipient,
                        fee_amount
                    );
                    
                    // Emit fee collected event
                    event::emit(WithdrawalFeeCollectedEvent {
                        user: user_addr,
                        fee_amount,
                        withdrawal_amount,
                        fee_recipient
                    });
                } else {
                    // If recipient not registered, add fee amount back to withdrawal
                    coin::transfer<AssetType>(
                        &delayed_withdrawal_signer,
                        receiver,
                        fee_amount
                    );
                };
            };
            
            // Update total pending assets
            user_requests.total_pending_assets = user_requests.total_pending_assets - total_claimable;
        
        // Emit withdrawal event
        event::emit(WithdrawEvent {
            withdrawer: user_addr,
            receiver,
            owner: user_addr,
                assets: withdrawal_amount, // Report the amount after fee
                shares: 0,
                timestamp: timestamp::now_seconds(),
                block_height: block::get_current_block_height()
            });
        };
    }

    // Helper function to process actual withdrawal
    fun process_withdrawal<AssetType>(
        user: &signer,
        receiver: address,
        assets: u64,
        _shares: u64,
        is_delayed_withdrawal: bool,
        withdrawal_fee: u64,
        fee_recipient: address
    ) acquires VaultCapability {
        let user_addr = signer::address_of(user);
        
        // Get vault signer
        let vault_signer = get_vault_signer();
        
        // Registration if needed
        if (!coin::is_account_registered<AssetType>(receiver)) {
            if (receiver == user_addr) {
                coin::register<AssetType>(user);
            } else {
                assert!(false, ERR_NOT_AUTHORIZED);
            };
        };
        
        // For immediate withdrawals, apply the fee now
        // For delayed withdrawals, transfer full amount to the holding account
        if (!is_delayed_withdrawal) {
            // Calculate fee amount
            let fee_amount = if (withdrawal_fee > 0) {
                let fee_u128 = (assets as u128) * (withdrawal_fee as u128) / (FEE_PRECISION as u128);
                (fee_u128 as u64)
            } else {
                0
            };
            
            // Calculate final withdrawal amount after fee
            let withdrawal_amount = assets - fee_amount;
            
            // Transfer withdrawal amount to receiver
            coin::transfer<AssetType>(&vault_signer, receiver, withdrawal_amount);
            
            // Transfer fee to fee recipient if non-zero
            if (fee_amount > 0) {
                // Ensure fee recipient is registered for this asset type
                if (coin::is_account_registered<AssetType>(fee_recipient)) {
                    coin::transfer<AssetType>(
                        &vault_signer,
                        fee_recipient,
                        fee_amount
                    );
                    
                    // Emit fee collected event
                    event::emit(WithdrawalFeeCollectedEvent {
                        user: user_addr,
                        fee_amount,
                        withdrawal_amount,
                        fee_recipient
                    });
                } else {
                    // If recipient not registered, add fee amount back to withdrawal
                    coin::transfer<AssetType>(&vault_signer, receiver, fee_amount);
                };
            };
        } else {
            // For delayed withdrawals, just transfer the full amount to the holding account
        coin::transfer<AssetType>(&vault_signer, receiver, assets);
        }
    }

    public entry fun redeem<AssetType>(
        user: &signer,
        shares: u64
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability, DelayedWithdrawalCapability {
        redeem_internal<AssetType>(
            user,
            shares,
            signer::address_of(user),
            signer::address_of(user)
        );
    }

    public entry fun redeem_to<AssetType>(
        user: &signer,
        shares: u64,
        receiver: address
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability, DelayedWithdrawalCapability {
        redeem_internal<AssetType>(
            user,
            shares,
            receiver,
            signer::address_of(user)
        );
    }

    fun redeem_internal<AssetType>(
        user: &signer,
        shares: u64,
        receiver: address,
        owner: address
    ) acquires VaultInfo, VaultCapability, ShareTokenCapability, DelayedWithdrawalCapability {
        let user_addr = signer::address_of(user);
        assert!(user_addr == owner, ERR_NOT_AUTHORIZED);
        
        // Get necessary information in a scope that will be closed
        let delay: u64;
        let matches_asset_type: bool;
        let is_paused: bool;
        let withdrawal_fee: u64;
        let min_withdrawal_amount: u64;
        {
            let vault = borrow_global<VaultInfo>(@vault);
            is_paused = vault.paused;
            matches_asset_type = type_of<AssetType>() == vault.asset_type;
            delay = vault.withdraw_delay;
            withdrawal_fee = vault.withdrawal_fee;
            min_withdrawal_amount = vault.min_withdrawal_amount;
        }; // Scope ends, borrow released
        
        // Check assertions
        assert!(!is_paused, ERR_VAULT_PAUSED);
        assert!(matches_asset_type, ERR_INVALID_ASSET_TYPE);
        
        // Calculate assets based on shares
        let assets = preview_redeem<AssetType>(shares);
        let user_share_balance = coin::balance<VaultShare>(user_addr);
        assert!(shares <= user_share_balance, ERR_INSUFFICIENT_SHARES);

        if (withdrawal_fee > 0) {
            assert!(assets >= min_withdrawal_amount, ERR_WITHDRAWAL_TOO_SMALL);
        };

        // Burn shares immediately in all cases
        let share_cap = borrow_global<ShareTokenCapability>(@vault);
        let share_tokens = coin::withdraw<VaultShare>(user, shares);
        coin::burn(share_tokens, &share_cap.burn_cap);
        
        // Update vault accounting
        let vault = borrow_global_mut<VaultInfo>(@vault);
        vault.total_shares = vault.total_shares - shares;
        vault.total_assets = vault.total_assets - assets;
            
        // If no delay, process immediately
       if (delay == 0) {
            // Process withdrawal immediately
            let withdrawal_fee = vault.withdrawal_fee;
            let fee_recipient = vault.fee_recipient;
            process_withdrawal<AssetType>(user, receiver, assets, shares, false, withdrawal_fee, fee_recipient);
            
            // Emit withdrawal event
            event::emit(WithdrawEvent {
                withdrawer: user_addr,
                receiver,
                owner,
                assets,
                shares,
                timestamp: timestamp::now_seconds(),
                block_height: block::get_current_block_height()
            });
        } else {
            // Create withdrawal request
            let vault_signer = get_vault_signer();
            let delayed_withdrawal_signer = get_delayed_withdrawal_signer();
            
            // Process withdrawal to delayed withdrawal account
            let withdrawal_fee = vault.withdrawal_fee;
            let fee_recipient = vault.fee_recipient;
            process_withdrawal<AssetType>(
                &vault_signer,
                signer::address_of(&delayed_withdrawal_signer),
                assets,
                shares,
                true,
                withdrawal_fee,
                fee_recipient
            );
            
            let request_time = timestamp::now_seconds();
            
            // Initialize user's withdraw requests if not exists
            if (!table::contains(&vault.withdraw_requests, user_addr)) {
                table::add(&mut vault.withdraw_requests, user_addr, UserWithdrawRequests {
                    requests: table::new(),
                    request_ids: vector::empty(),
                    next_request_id: 0,
                    total_pending_assets: 0
                });
            };

            let user_requests = table::borrow_mut(&mut vault.withdraw_requests, user_addr);
            let request_id = user_requests.next_request_id;
            user_requests.next_request_id = request_id + 1;
            user_requests.total_pending_assets = user_requests.total_pending_assets + assets;

            // Add request ID to the vector for tracking
            vector::push_back(&mut user_requests.request_ids, request_id);
            let request_delay = vault.withdraw_delay;
            table::add(&mut user_requests.requests, request_id, WithdrawRequest {
                assets,
                request_time,
                processed: false,
                request_id,
                delay_at_request: request_delay
            });

            // Emit withdrawal request event
            event::emit(WithdrawRequestEvent {
                user: user_addr,
                assets,              
                request_time: request_time,
                timestamp: timestamp::now_seconds(),
                block_height: block::get_current_block_height()
            });
        }
    }


    
    // Helper function to get vault signer
    fun get_vault_signer(): signer acquires VaultCapability {
        account::create_signer_with_capability(&borrow_global<VaultCapability>(@vault).cap)
    }

    #[view]
    public fun get_vault_resource_address(): address acquires VaultCapability {
        let vault_signer = get_vault_signer();
        signer::address_of(&vault_signer)
    }

    fun get_delayed_withdrawal_signer(): signer acquires DelayedWithdrawalCapability {
        account::create_signer_with_capability(
            &borrow_global<DelayedWithdrawalCapability>(@vault).cap
        )
    }
   

    #[view]
    public fun convert_to_shares<AssetType>(assets: u64): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        let supply = vault.total_shares;
        let total = total_assets<AssetType>();
        
        // Handle initial conversion case
        if (assets == 0 || supply == 0) {
            return assets // Initial conversion rate of 1:1
        };
        
        // Prevent overflow by using a two-step approach with high precision
        let assets_with_precision = (assets as u128) * (PRECISION as u128);
        let shares_precise = (assets_with_precision * (supply as u128)) / (total as u128);
        
        // Divide by PRECISION to get back to normal scale
        let shares_precise = shares_precise / (PRECISION as u128);
        
        // Convert back to u64 with safety check
        assert!(shares_precise <= (MAX_U64 as u128), ERR_MATH_OVERFLOW);
        (shares_precise as u64)
    }

    #[view]
    public fun convert_to_assets<AssetType>(shares: u64): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        let supply = vault.total_shares;
        let total = total_assets<AssetType>();
        
        if (supply == 0) {
            return shares
        };
        
        // Use u128 for intermediate calculations to prevent overflow
        let shares_with_precision = (shares as u128) * (PRECISION as u128);
        let assets_precise = (shares_with_precision * (total as u128)) / (supply as u128);
        
        // Divide by PRECISION to get back to normal scale
        let assets_precise = assets_precise / (PRECISION as u128);
        
        // Convert back to u64 with safety check
        assert!(assets_precise <= (MAX_U64 as u128), ERR_MATH_OVERFLOW);
        (assets_precise as u64)
    }

    /// Preview functions to simulate operations
    #[view]
    public fun preview_deposit<AssetType>(assets: u64): u64 acquires VaultInfo {
        convert_to_shares<AssetType>(assets)
    }

    #[view] 
    public fun preview_mint<AssetType>(shares: u64): u64 acquires VaultInfo {
        convert_to_assets<AssetType>(shares)
    }

    #[view]
    public fun preview_redeem<AssetType>(shares: u64): u64 acquires VaultInfo {
        convert_to_assets<AssetType>(shares)
    }


    #[view]
    public fun preview_withdraw<AssetType>(assets: u64): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        let shares_supply = vault.total_shares;
        let total_assets_amount = total_assets<AssetType>();
        
        if (total_assets_amount == 0 || shares_supply == 0) {
             assets // Initial conversion rate of 1:1
        } else {
            // Use u128 for intermediate calculations to prevent overflow
            let shares_precise = ((assets as u128) * (shares_supply as u128)) / (total_assets_amount as u128);
            
            // Round up by checking remainder
            let remainder = ((assets as u128) * (shares_supply as u128)) % (total_assets_amount as u128);
            let shares = if (remainder > 0) { shares_precise + 1 } else { shares_precise };
            
            // Safety check
            assert!(shares <= (MAX_U64 as u128), ERR_MATH_OVERFLOW);
            (shares as u64)

            // assert!(shares_precise <= (MAX_U64 as u128), ERR_MATH_OVERFLOW);
            // (shares_precise as u64)
        }
    }

    public entry fun pause(admin: &signer) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        vault.paused = true;
        event::emit(PausedEvent {});
    }
    public entry fun unpause(admin: &signer) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        vault.paused = false;
        event::emit(UnpausedEvent {});
    }

    public entry fun set_tvl_limit<AssetType>(admin: &signer, new_limit: u64) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_limit = vault.tvl_limit;
        vault.tvl_limit = new_limit;
        event::emit(TvlLimitUpdatedEvent { old_limit, new_limit });
    }

    public entry fun set_performance_fee(admin: &signer, new_fee: u64) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_fee = vault.performance_fee;
        vault.performance_fee = new_fee;
        event::emit(PerformanceFeeUpdatedEvent { old_fee, new_fee });
    }

    public entry fun harvest<AssetType, CollateralType>(admin: &signer, user_addr: address) acquires VaultInfo, VaultCapability {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);

        let vault_signer = get_vault_signer();
        let vault_addr = signer::address_of(&vault_signer);
        
        // Get strategy address
        let strategy_signer = strategy_core::get_strategy_signer();
        let strategy_addr = signer::address_of(&strategy_signer);
        let available_assets = coin::balance<AssetType>(vault_addr);

        if (available_assets > 0) {
            // First transfer assets to strategy's resource account
            coin::transfer<AssetType>(
                &vault_signer,
                strategy_addr,
                available_assets
            );
        };
        
        // Get vault info BEFORE strategy calls to avoid conflicts
        let (total_assets, performance_fee, fee_recipient, asset_type);
        {
            let vault = borrow_global<VaultInfo>(@vault);
            total_assets = vault.total_assets;
            performance_fee = vault.performance_fee;
            fee_recipient = vault.fee_recipient;
            asset_type = vault.asset_type;
        }; // Release the borrow
        
        // Assert that AssetType matches the vault's asset type
        assert!(type_of<AssetType>() == asset_type, ERR_INVALID_ASSET_TYPE);
        strategy_core::execute_liquidate<AssetType, CollateralType>(
            user_addr
        );
        
        // Get the new balance from the vault's resource account
        let new_balance = coin::balance<AssetType>(vault_addr);
        let difference = 0;
        let is_yield = false;
        let fee_amount = 0;
        if (new_balance > total_assets) {
                difference = new_balance - total_assets;
                is_yield = true;
                fee_amount = (((difference as u128) * (performance_fee as u128) / (FEE_PRECISION as u128)) as u64);
        } else {
                difference = total_assets - new_balance;
                is_yield = false;
        };
        let vault = borrow_global_mut<VaultInfo>(@vault);
        if (is_yield) {
            vault.total_assets = vault.total_assets + difference - fee_amount;
        } else {
            vault.total_assets = vault.total_assets - difference;
        };

        if (fee_amount > 0) {
            coin::transfer<AssetType>(
                &vault_signer,
                fee_recipient,
                fee_amount
            );
        };

        event::emit(YieldGeneratedEvent { 
            yield_amount: difference,
            fee_amount,
            remaining_yield: difference - fee_amount,
            fee_recipient
        });

    }

    // Add the new permissionless harvest function
    public entry fun harvest_permissionless<AssetType, CollateralType>(user_addr: address) acquires VaultInfo, VaultCapability {
        let vault_signer = get_vault_signer();
        let vault_addr = signer::address_of(&vault_signer);
        
        // Get strategy address
        let strategy_signer = strategy_core::get_strategy_signer();
        let strategy_addr = signer::address_of(&strategy_signer);
        let available_assets = coin::balance<AssetType>(vault_addr);

        if (available_assets > 0) {
            // First transfer assets to strategy's resource account
            coin::transfer<AssetType>(
                &vault_signer,
                strategy_addr,
                available_assets
            );
        };
        
        // Get vault info BEFORE strategy calls to avoid conflicts
        let (total_assets, performance_fee, fee_recipient, asset_type);
        {
            let vault = borrow_global<VaultInfo>(@vault);
            total_assets = vault.total_assets;
            performance_fee = vault.performance_fee;
            fee_recipient = vault.fee_recipient;
            asset_type = vault.asset_type;
        }; // Release the borrow
        
        // Assert that AssetType matches the vault's asset type
        assert!(type_of<AssetType>() == asset_type, ERR_INVALID_ASSET_TYPE);
        strategy_core::execute_liquidate<AssetType, CollateralType>(
            user_addr
        );
        
        // Get the new balance from the vault's resource account
        let new_balance = coin::balance<AssetType>(vault_addr);
        let difference = 0;
        let is_yield = false;
        let fee_amount = 0;
        if (new_balance > total_assets) {
                difference = new_balance - total_assets;
                is_yield = true;
                fee_amount = (((difference as u128) * (performance_fee as u128) / (FEE_PRECISION as u128)) as u64);
        } else {
                difference = total_assets - new_balance;
                is_yield = false;
        };
        let vault = borrow_global_mut<VaultInfo>(@vault);
        if (is_yield) {
            vault.total_assets = vault.total_assets + difference - fee_amount;
        } else {
            vault.total_assets = vault.total_assets - difference;
        };

        if (fee_amount > 0) {
            coin::transfer<AssetType>(
                &vault_signer,
                fee_recipient,
                fee_amount
            );
        };

        event::emit(YieldGeneratedEvent { 
            yield_amount: difference,
            fee_amount,
            remaining_yield: difference - fee_amount,
            fee_recipient
        });

    }

    // public entry fun harvest_aggregator<
    //     CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
    //     Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
    //     Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
    //     Coin30, AssetType
    // >(
    //     _fund_mangager: &signer,
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
    // ) acquires VaultInfo, VaultCapability ,FundManagerInfo{
    //     let caller_addr = signer::address_of(_fund_mangager);
    //     assert!(is_fund_manager(caller_addr), ERR_NOT_FUND_MANAGER);

    //     // assert!(signer::address_of(_user_signer) == @vault, ERR_NOT_ADMIN);
    //     let vault_signer = get_vault_signer();
    //     let vault_addr = signer::address_of(&vault_signer);
        
    //     // Get strategy address
    //     let strategy_signer = strategy_core::get_strategy_signer();
    //     let strategy_addr = signer::address_of(&strategy_signer);
    //     let available_assets = coin::balance<AssetType>(vault_addr);

    //     if (available_assets > 0) {
    //         // First transfer assets to strategy's resource account
    //         coin::transfer<AssetType>(
    //             &vault_signer,
    //             strategy_addr,
    //             available_assets
    //         );
    //     };
        
    //     // Get vault info BEFORE strategy calls to avoid conflicts
    //     let (total_assets, performance_fee, fee_recipient, asset_type);
    //     {
    //         let vault = borrow_global<VaultInfo>(@vault);
    //         total_assets = vault.total_assets;
    //         performance_fee = vault.performance_fee;
    //         fee_recipient = vault.fee_recipient;
    //         asset_type = vault.asset_type;
    //     }; // Release the borrow
        
    //     // Assert that AssetType matches the vault's asset type
    //     assert!(type_of<AssetType>() == asset_type, ERR_INVALID_ASSET_TYPE);
    //     strategy_core::execute_liquidate_aggregator<
    //     CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
    //     Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
    //     Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
    //     Coin30, AssetType>(_swap_mode,_split_count,_step_counts,_dex_types,_pool_ids,_is_x_to_y,_pool_types,_token_addresses,_token_x_addresses,_token_y_addresses,_extra_data,_step_amounts,_extra_dex_types,_output_token_address,_split_amounts,_min_output_amount,_fee_basis_points,_integrator_address,user_addr
    //     );
        
    //     // Get the new balance from the vault's resource account
    //     let new_balance = coin::balance<AssetType>(vault_addr);
    //     let difference = 0;
    //     let is_yield = false;
    //     let fee_amount = 0;
    //     if (new_balance > total_assets) {
    //             difference = new_balance - total_assets;
    //             is_yield = true;
    //             fee_amount = (((difference as u128) * (performance_fee as u128) / (FEE_PRECISION as u128)) as u64);
    //     } else {
    //             difference = total_assets - new_balance;
    //             is_yield = false;
    //     };
    //     let vault = borrow_global_mut<VaultInfo>(@vault);
    //     if (is_yield) {
    //         vault.total_assets = vault.total_assets + difference - fee_amount;
    //     } else {
    //         vault.total_assets = vault.total_assets - difference;
    //     };

    //     if (fee_amount > 0) {
    //         coin::transfer<AssetType>(
    //             &vault_signer,
    //             fee_recipient,
    //             fee_amount
    //         );
    //     };

    //     event::emit(YieldGeneratedEvent { 
    //         yield_amount: difference,
    //         fee_amount,
    //         remaining_yield: difference - fee_amount,
    //         fee_recipient
    //     });
    // }

    public entry fun harvest_aggregator<
        CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
        Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
        Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
        Coin30, AssetType
    >(
        fund_mangager: &signer,
        user_addr: address
    ) acquires VaultInfo, VaultCapability ,FundManagerInfo{
        let fund_addr = signer::address_of(fund_mangager);
        assert!(is_fund_manager(fund_addr), ERR_NOT_FUND_MANAGER);

        // assert!(signer::address_of(_user_signer) == @vault, ERR_NOT_ADMIN);
        let vault_signer = get_vault_signer();
        let vault_addr = signer::address_of(&vault_signer);
        
        // Get strategy address
        let strategy_signer = strategy_core::get_strategy_signer();
        let strategy_addr = signer::address_of(&strategy_signer);
        let available_assets = coin::balance<AssetType>(vault_addr);

        if (available_assets > 0) {
            // First transfer assets to strategy's resource account
            coin::transfer<AssetType>(
                &vault_signer,
                strategy_addr,
                available_assets
            );
        };
        
        // Get vault info BEFORE strategy calls to avoid conflicts
        let (total_assets, performance_fee, fee_recipient, asset_type);
        {
            let vault = borrow_global<VaultInfo>(@vault);
            total_assets = vault.total_assets;
            performance_fee = vault.performance_fee;
            fee_recipient = vault.fee_recipient;
            asset_type = vault.asset_type;
        }; // Release the borrow

        strategy_core::execute_liquidate_aggregator<CollateralType, Coin1, Coin2, Coin3, Coin4, Coin5, Coin6, Coin7, Coin8, Coin9,
        Coin10, Coin11, Coin12, Coin13, Coin14, Coin15, Coin16, Coin17, T18, Coin19,
        Coin20, Coin21, Coin22, Coin23, Coin24, Coin25, Coin26, Coin27, Coin28, Coin29,
        Coin30, AssetType>(
            fund_addr,  // NEW: Pass for transfer
            user_addr
        );
        
    }



    public entry fun sync_assets<AssetType>(admin: &signer) acquires VaultInfo, VaultCapability {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        
        // Get vault signer and actual vault balance
        let vault_signer = get_vault_signer();
        let vault_addr = signer::address_of(&vault_signer);
        let actual_vault_balance = coin::balance<AssetType>(vault_addr);
        
        // Update internal accounting
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_total = vault.total_assets;
        vault.total_assets = actual_vault_balance;
        
        // Calculate difference and emit event
        let difference = if (actual_vault_balance > old_total) {
            actual_vault_balance - old_total
        } else {
            old_total - actual_vault_balance
        };
        
        event::emit(AssetsSyncedEvent {
            old_total,
            new_total: actual_vault_balance,
            difference
        });
    }

    // UPDATED: Make callable by fund_manager (add check); move yield/fee here if not already
    // public entry fun sync_assets<AssetType>(
    //     caller: &signer
    // ) acquires VaultInfo, VaultCapability {
    //     let caller_addr = signer::address_of(caller);
    //     assert!(signer::address_of(caller) == @vault, ERR_NOT_ADMIN);

    //     let vault_signer = get_vault_signer();
    //     let vault_addr = signer::address_of(&vault_signer);
    //     let actual_balance = coin::balance<AssetType>(vault_addr);  // + strategy if needed

    //     let vault = borrow_global_mut<VaultInfo>(@vault);
    //     let old_total = vault.total_assets;
    //     let difference = if (actual_balance > old_total) { actual_balance - old_total } else { old_total - actual_balance };
    //     let is_yield = actual_balance > old_total;

    //     if (is_yield) {
    //         let fee_amount = (((difference as u128) * (vault.performance_fee as u128) / (FEE_PRECISION as u128)) as u64);
    //         vault.total_assets = vault.total_assets + (difference - fee_amount);  // Add net yield

    //         if (fee_amount > 0) {
    //             coin::transfer<AssetType>(&vault_signer, vault.fee_recipient, fee_amount);
    //         };

    //         event::emit(YieldGeneratedEvent {
    //             yield_amount: difference,
    //             fee_amount,
    //             remaining_yield: difference - fee_amount,
    //             fee_recipient: vault.fee_recipient
    //         });
    //     } else {
    //         vault.total_assets = vault.total_assets - difference;  // Loss adjustment
    //     };

    //     event::emit(AssetsSyncedEvent { old_total, new_total: actual_balance, difference });
    // }


    fun is_fund_manager(signer_addr: address): bool acquires FundManagerInfo {
        if (!exists<FundManagerInfo>(@vault)) {
            false
        } else {
            let fund_manager_info = borrow_global<FundManagerInfo>(@vault);
            signer_addr == fund_manager_info.fund_manager
        }
    }


     public entry fun set_fund_manager(admin: &signer, fund_manager: address) acquires FundManagerInfo {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @vault, ERR_NOT_ADMIN);
        
        let old_manager = if (exists<FundManagerInfo>(@vault)) {
            let fund_manager_info = borrow_global_mut<FundManagerInfo>(@vault);
            let old_addr = fund_manager_info.fund_manager;
            fund_manager_info.fund_manager = fund_manager;
            old_addr
        } else {
            // First time setting fund manager
            move_to(admin, FundManagerInfo {
                fund_manager
            });
            @0x0 // Use null address as "old" value for first setup
        };
        
        event::emit(FundManagerUpdatedEvent {
            old_manager,
            new_manager: fund_manager
        });
    }


    // Set the withdrawal delay
    public entry fun set_withdraw_delay(admin: &signer, delay: u64) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_delay = vault.withdraw_delay;
        vault.withdraw_delay = delay;
        event::emit(WithdrawDelayUpdatedEvent { old_delay, new_delay: delay });
    }

    public entry fun set_fee_recipient(admin: &signer, new_fee_recipient: address) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_recipient = vault.fee_recipient;
        vault.fee_recipient = new_fee_recipient;
        event::emit(FeeRecipientUpdatedEvent { old_recipient, new_recipient: new_fee_recipient });
    }

    public entry fun set_withdrawal_fee(admin: &signer, new_fee: u64) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        // Optional: Add boundary check to ensure fee is reasonable
        assert!(new_fee <= FEE_PRECISION / 10, ERR_MATH_OVERFLOW); // Max 10%
        
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_fee = vault.withdrawal_fee;
        vault.withdrawal_fee = new_fee;
        event::emit(WithdrawalFeeUpdatedEvent { old_fee, new_fee });
    }

    #[view]
    public fun total_assets<AssetType>(): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        
        // Combine internal accounting with strategy balance
        vault.total_assets + strategy_core::balance_of<AssetType>()
    }

    #[view]
    public fun total_shares(): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        
        // Combine internal accounting with strategy balance
        vault.total_shares
    }


    #[view]
    public fun is_account_ready<AssetType>(account_addr: address): bool {
        coin::is_account_registered<AssetType>(account_addr) && 
        coin::is_account_registered<VaultShare>(account_addr)
    }

    public entry fun initialize_account<AssetType>(account: &signer) {
        if (!coin::is_account_registered<AssetType>(signer::address_of(account))) {
            coin::register<AssetType>(account);
        };
        if (!coin::is_account_registered<VaultShare>(signer::address_of(account))) {
            coin::register<VaultShare>(account);
        };
    }




    #[test_only]
    public fun get_vault_signer_for_testing(): signer acquires VaultCapability {
        get_vault_signer()
    }

    /// Max operation limits
    #[view]
    public fun max_deposit<AssetType>(_user: address): u64 acquires VaultInfo {
        // Get the current total assets before borrowing VaultInfo
        let current_tvl = total_assets<AssetType>();
        
        // Now borrow VaultInfo
        let vault = borrow_global<VaultInfo>(@vault);
        
        if (vault.paused) {
            0
        } else if (vault.tvl_limit == 0) {
            MAX_U64
        } else {
            if (current_tvl >= vault.tvl_limit) {
                0
            } else {
                vault.tvl_limit - current_tvl
            }
        }
    }

    #[view]
    public fun max_mint<AssetType>(_user: address): u64 {
        MAX_U64
    }

    #[view]
    public fun max_withdraw<AssetType>(user: address): u64 acquires VaultInfo {
        let shares = coin::balance<VaultShare>(user);
        convert_to_assets<AssetType>(shares)
    }

    #[view]
    public fun max_redeem(user: address): u64 {
        coin::balance<VaultShare>(user)
    }

    #[view]
    public fun has_pending_withdrawal(user: address): bool acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        if (!table::contains(&vault.withdraw_requests, user)) {
            return false
        };
        
        let user_requests = table::borrow(&vault.withdraw_requests, user);
        let request_ids_len = vector::length(&user_requests.request_ids);
        
        let i = 0;
        while (i < request_ids_len) {
            let request_id = *vector::borrow(&user_requests.request_ids, i);
            if (table::contains(&user_requests.requests, request_id)) {
                let request = table::borrow(&user_requests.requests, request_id);
                if (!request.processed) {
                    return true
                };
            };
            i = i + 1;
        };
        
        false
    }
    
    #[view]
    public fun get_withdrawal_details(user: address): (u64, u64, bool) acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        assert!(table::contains(&vault.withdraw_requests, user), ERR_NOT_AUTHORIZED);
        
        let user_requests = table::borrow(&vault.withdraw_requests, user);
        let request_ids_len = vector::length(&user_requests.request_ids);
        
        // Return details of first unprocessed request, if any
        let i = 0;
        while (i < request_ids_len) {
            let request_id = *vector::borrow(&user_requests.request_ids, i);
            if (table::contains(&user_requests.requests, request_id)) {
                let request = table::borrow(&user_requests.requests, request_id);
                if (!request.processed) {
                    return (request.assets, request.request_time, request.processed)
                };
            };
            i = i + 1;
        };
        
        // If no pending requests, return zeros
        (0, 0, true)
    }

    // Add new view functions
    #[view]
    public fun get_claimable_amount<AssetType>(user: address): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        if (!table::contains(&vault.withdraw_requests, user)) {
            return 0
        };
        
        let user_requests = table::borrow(&vault.withdraw_requests, user);
        let current_time = timestamp::now_seconds();
        let delay = vault.withdraw_delay;
        let claimable_amount = 0;
        
        let request_ids_len = vector::length(&user_requests.request_ids);
        
        let i = 0;
        while (i < request_ids_len) {
            let request_id = *vector::borrow(&user_requests.request_ids, i);
            if (table::contains(&user_requests.requests, request_id)) {
                let request = table::borrow(&user_requests.requests, request_id);
                if (!request.processed && current_time >= request.request_time + delay) {
                    claimable_amount = claimable_amount + request.assets;
                };
            };
            i = i + 1;
        };
        
        claimable_amount
    }

    #[view]
    public fun get_all_pending_requests(user: address): (vector<u64>, vector<u64>, vector<bool>, vector<u64>) acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        assert!(table::contains(&vault.withdraw_requests, user), ERR_NOT_AUTHORIZED);
        
        let user_requests = table::borrow(&vault.withdraw_requests, user);
        let request_ids_len = vector::length(&user_requests.request_ids);
        
        // Create separate vectors for each field
        let assets_vec = vector::empty<u64>();
        let request_time_vec = vector::empty<u64>();
        let processed_vec = vector::empty<bool>();
        let request_id_vec = vector::empty<u64>();
        
        let i = 0;
        while (i < request_ids_len) {
            let request_id = *vector::borrow(&user_requests.request_ids, i);
            if (table::contains(&user_requests.requests, request_id)) {
                let request = table::borrow(&user_requests.requests, request_id);
                if (!request.processed) {
                    vector::push_back(&mut assets_vec, request.assets);
                    vector::push_back(&mut request_time_vec, request.request_time);
                    vector::push_back(&mut processed_vec, request.processed);
                    vector::push_back(&mut request_id_vec, request.request_id);
                };
            };
            i = i + 1;
        };
        
        (assets_vec, request_time_vec, processed_vec, request_id_vec)
    }

     // Test-only version of harvest that doesn't rely on strategy_core
    #[test_only]
    public fun harvest_test<AssetType>(admin: &signer, user_addr: address) acquires VaultInfo, VaultCapability {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @vault, ERR_NOT_ADMIN);

        let vault_signer = get_vault_signer_for_testing();
        let vault_addr = signer::address_of(&vault_signer);
        
        // Since we're testing, we don't need to call strategy_core functions
        // We've already simulated yield by transferring directly to vault
        
        // Get current balance (after we added simulated yield)
        let current_balance = coin::balance<AssetType>(vault_addr);
        
        // Get the vault info
        let vault = borrow_global_mut<VaultInfo>(@vault);
        
        // Calculate yield as the difference between current balance and recorded assets
        let yield_amount = current_balance - vault.total_assets;
        
        if (yield_amount > 0) {
            let fee_percentage = vault.performance_fee;
            let fee_recipient = vault.fee_recipient;
            
            // Calculate fee amount
            let fee_amount = if (fee_percentage > 0) {
                // Calculate fee amount with proper precision
                let fee_u128 = (yield_amount as u128) * (fee_percentage as u128) / (FEE_PRECISION as u128);
                (fee_u128 as u64)
            } else {
                0
            };
            
            // Transfer fee to fee recipient if non-zero
            if (fee_amount > 0) {
                if (coin::is_account_registered<AssetType>(fee_recipient)) {
                    coin::transfer<AssetType>(
                        &vault_signer,
                        fee_recipient,
                        fee_amount
                    );
                };
            };
            
            // Calculate remaining yield after fee
            let remaining_yield = yield_amount - fee_amount;
            
            // Update vault accounting with remaining yield
            vault.total_assets = vault.total_assets + remaining_yield;
            
            // Emit yield event with fee information
            event::emit(YieldGeneratedEvent { 
                yield_amount,
                fee_amount,
                remaining_yield,
                fee_recipient
            });
        };
    }

    // Add a function for admins to update the minimum withdrawal amount
    public entry fun set_min_withdrawal_amount(admin: &signer, new_amount: u64) acquires VaultInfo {
        assert!(signer::address_of(admin) == @vault, ERR_NOT_ADMIN);
        
        let vault = borrow_global_mut<VaultInfo>(@vault);
        let old_amount = vault.min_withdrawal_amount;
        vault.min_withdrawal_amount = new_amount;
        
        // Emit event for the update
        event::emit(MinWithdrawalAmountUpdatedEvent {
            old_amount,
            new_amount
        });
    }

    // Add a view function to get the current minimum withdrawal amount
    #[view]
    public fun get_min_withdrawal_amount(): u64 acquires VaultInfo {
        let vault = borrow_global<VaultInfo>(@vault);
        vault.min_withdrawal_amount
    }

     #[view]
    public fun get_fund_manager(): address acquires FundManagerInfo {
        if (!exists<FundManagerInfo>(@vault)) {
            @0x0 // Return null address if not set
        } else {
            let fund_manager_info = borrow_global<FundManagerInfo>(@vault);
            fund_manager_info.fund_manager
        }
    }

    
}