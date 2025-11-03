module cdp::config {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info::{Self, TypeInfo};
    use cdp::events;
    use cdp::price_oracle;

    // const FEE_COLLECTOR: address = @0x2db5c23e86ef48e8604685b14017a3c2625484ebf33d84d80c4541daf44c459a;


    friend cdp::cdp_multi;

    struct CollateralConfig has store, copy, drop {
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_reserve: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        redemption_fee: u64,
        enabled: bool,
        decimals: u8,
        liquidation_fee_protocol: u64,
        redemption_fee_gratuity: u64
    }

    struct TroveOperationStatus has store, copy, drop {
        open_trove: bool,
        borrow: bool,
        deposit: bool,
        redeem: bool,
    }

    struct CollateralRegistry has key {
        configs: Table<TypeInfo, CollateralConfig>,
        operation_status: Table<TypeInfo, TroveOperationStatus>,
        fee_collector: address,
    }

    public(friend) fun initialize(admin: &signer, fee_collector: address) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<CollateralRegistry>(admin_addr), events::err_already_initialized());
        move_to(admin, CollateralRegistry {
            configs: table::new(),
            operation_status: table::new(),
            fee_collector,
        });
    }

    public(friend) fun add_collateral<CoinType>(
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_reserve: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        redemption_fee: u64,
        decimals: u8,
        liquidation_fee_protocol: u64,
        redemption_fee_gratuity: u64,
        oracle_id: u32,
        price_age: u64
    ) acquires CollateralRegistry {
        let registry = borrow_global_mut<CollateralRegistry>(@cdp);
        let config = CollateralConfig {
            minimum_debt,
            mcr,
            borrow_rate,
            liquidation_reserve,
            liquidation_threshold,
            liquidation_penalty,
            redemption_fee,
            enabled: true,
            decimals,
            liquidation_fee_protocol,
            redemption_fee_gratuity
        };

        let status = TroveOperationStatus {
            open_trove: true,
            borrow: true,
            deposit: true,
            redeem: true,
        };

        table::add(&mut registry.operation_status, type_info::type_of<CoinType>(), status);
        table::add(&mut registry.configs, type_info::type_of<CoinType>(), config);
        price_oracle::set_oracle<CoinType>(oracle_id, price_age);
    }

    public(friend) fun set_config<CoinType>(
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        redemption_fee: u64,
        enabled: bool,
        liquidation_fee_protocol: u64,
        redemption_fee_gratuity: u64
    ) acquires CollateralRegistry {
        let registry = borrow_global_mut<CollateralRegistry>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        
        assert!(table::contains(&registry.configs, collateral_type), events::err_unsupported_collateral());
        
        let existing_config = table::borrow(&registry.configs, collateral_type);
        let liquidation_reserve = existing_config.liquidation_reserve;
        let decimals = existing_config.decimals;
        
        let new_config = CollateralConfig {
            minimum_debt,
            mcr,
            borrow_rate,
            liquidation_reserve,
            liquidation_threshold,
            liquidation_penalty,
            redemption_fee,
            enabled,
            decimals,
            liquidation_fee_protocol,
            redemption_fee_gratuity
        };
        
        *table::borrow_mut(&mut registry.configs, collateral_type) = new_config;
    }

    public(friend) fun set_operation_status<CoinType>(
        open_trove: bool,
        borrow: bool,
        deposit: bool,
        redeem: bool
    ) acquires CollateralRegistry {
        let registry = borrow_global_mut<CollateralRegistry>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        
        assert!(table::contains(&registry.configs, collateral_type), events::err_unsupported_collateral());
        
        let status = TroveOperationStatus {
            open_trove,
            borrow,
            deposit,
            redeem,
        };
        
        *table::borrow_mut(&mut registry.operation_status, collateral_type) = status;
    }

    public(friend) fun set_fee_collector( new_fee_collector: address) acquires CollateralRegistry {
        let registry = borrow_global_mut<CollateralRegistry>(@cdp);
        registry.fee_collector = new_fee_collector;
    }

    // View functions
    #[view]
    public fun get_config<CoinType>(): (u64, u64, u64, u64, u64, u64, u64, bool, u64, u64) 
    acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        let config = table::borrow(&registry.configs, collateral_type);
        
        (
            config.minimum_debt,
            config.mcr,
            config.borrow_rate,
            config.liquidation_reserve,
            config.liquidation_threshold,
            config.liquidation_penalty,
            config.redemption_fee,
            config.enabled,
            config.liquidation_fee_protocol,
            config.redemption_fee_gratuity
        )
    }

    #[view]
    public fun get_operation_status<CoinType>(): (bool, bool, bool, bool) 
    acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        
        if (!table::contains(&registry.operation_status, collateral_type)) {
            return (false, false, false, false)
        };
        
        let status = table::borrow(&registry.operation_status, collateral_type);
        (status.open_trove, status.borrow, status.deposit, status.redeem)
    }

    #[view]
    public fun is_valid_collateral<CoinType>(): bool acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        
        if (!table::contains(&registry.configs, collateral_type)) {
            return false
        };
        
        let config = table::borrow(&registry.configs, collateral_type);
        config.enabled
    }

    // Helper functions to access config values
    public(friend) fun get_minimum_debt<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).minimum_debt
    }

    public(friend) fun get_mcr<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).mcr
    }

    public(friend) fun get_borrow_rate<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).borrow_rate
    }

    public(friend) fun get_liquidation_reserve<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).liquidation_reserve
    }

    public(friend) fun get_liquidation_threshold<CoinType>(): u64 acquires CollateralRegistry {     
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).liquidation_threshold
    }

    public(friend) fun get_liquidation_penalty<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).liquidation_penalty
    }

    public(friend) fun get_redemption_fee<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).redemption_fee
    }

    public(friend) fun get_redemption_fee_gratuity<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).redemption_fee_gratuity
    }

    public(friend) fun get_liquidation_fee_protocol<CoinType>(): u64 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).liquidation_fee_protocol
    }

    public(friend) fun get_decimals<CoinType>(): u8 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).decimals
    }

    public(friend) fun get_enabled<CoinType>(): bool acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).enabled
    }

    public(friend) fun get_fee_collector(): address acquires CollateralRegistry{
        borrow_global<CollateralRegistry>(@cdp).fee_collector
    }

    public(friend) fun get_collateral_decimals<CoinType>(): u8 acquires CollateralRegistry {
        let registry = borrow_global<CollateralRegistry>(@cdp);
        table::borrow(&registry.configs, type_info::type_of<CoinType>()).decimals
    }
}
