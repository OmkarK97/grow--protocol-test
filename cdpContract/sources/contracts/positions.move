module cdp::positions {
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info::{Self, TypeInfo};
    use cdp::events;

    friend cdp::cdp_multi;

    // User position for a specific collateral type
    struct CollateralPosition has store, copy, drop {
        collateral_amount: u64,
        debt_amount: u64,
        last_update_time: u64,
    }

    // Combined user positions table
    struct UserPositions has key {
        positions: Table<address, Table<TypeInfo, CollateralPosition>>,
    }

    struct RedemptionProvider has key {
        providers: Table<address, Table<TypeInfo, bool>>
    }

    public(friend) fun initialize(admin: &signer) {
        move_to(admin, UserPositions {
            positions: table::new(),
        });
        move_to(admin, RedemptionProvider {
            providers: table::new(),
        });
    }

    public(friend) fun create_position<CoinType>(
        user_addr: address,
        collateral_amount: u64,
        debt_amount: u64,
        last_update_time: u64
    ) acquires UserPositions {
        let positions = borrow_global_mut<UserPositions>(@cdp);
        
        if (!table::contains(&positions.positions, user_addr)) {
            table::add(&mut positions.positions, user_addr, table::new());
        };

        let user_positions = table::borrow_mut(&mut positions.positions, user_addr);
        let collateral_type = type_info::type_of<CoinType>();
        assert!(!table::contains(user_positions, collateral_type), events::err_position_already_exists());
        
        let position = CollateralPosition {
            collateral_amount,
            debt_amount,
            last_update_time,
        };

        table::add(user_positions, collateral_type, position);
    }

    public(friend) fun update_position<CoinType>(
        user_addr: address,
        collateral_amount: u64,
        debt_amount: u64,
        last_update_time: u64
    ) acquires UserPositions {
        let positions = borrow_global_mut<UserPositions>(@cdp);
        let user_positions = table::borrow_mut(&mut positions.positions, user_addr);
        let position = table::borrow_mut(user_positions, type_info::type_of<CoinType>());
        
        position.collateral_amount = collateral_amount;
        position.debt_amount = debt_amount;
        position.last_update_time = last_update_time;
    }

    public(friend) fun remove_position<CoinType>(
        user_addr: address
    ) acquires UserPositions {
        let positions = borrow_global_mut<UserPositions>(@cdp);
        let user_positions = table::borrow_mut(&mut positions.positions, user_addr);
        table::remove(user_positions, type_info::type_of<CoinType>());
    }

    public(friend) fun register_redemption_provider<CoinType>(
        user_addr: address,
        opt_in: bool
    ) acquires RedemptionProvider {
        let providers = borrow_global_mut<RedemptionProvider>(@cdp);
        let collateral_type = type_info::type_of<CoinType>();
        
        if (!table::contains(&providers.providers, user_addr)) {
            table::add(&mut providers.providers, user_addr, table::new());
        };
        
        let user_providers = table::borrow_mut(&mut providers.providers, user_addr);
        if (opt_in) {
            table::upsert(user_providers, collateral_type, true);
        } else if (table::contains(user_providers, collateral_type)) {
            table::remove(user_providers, collateral_type);
        };
    }

    // View functions
    #[view]
    public fun get_position<CoinType>(
        user_addr: address
    ): (u64, u64, u64, bool) acquires UserPositions {
        let positions = borrow_global<UserPositions>(@cdp);
        
        if (!table::contains(&positions.positions, user_addr)) {
            return (0, 0, 0, false)
        };

        let user_positions = table::borrow(&positions.positions, user_addr);
        let collateral_type = type_info::type_of<CoinType>();
        
        if (!table::contains(user_positions, collateral_type)) {
            return (0, 0, 0, false)
        };

        let position = table::borrow(user_positions, collateral_type);
        (position.collateral_amount, position.debt_amount, position.last_update_time, true)
    }

    #[view]
    public fun is_redemption_provider<CoinType>(user_addr: address): bool acquires RedemptionProvider {
        let providers = borrow_global<RedemptionProvider>(@cdp);
        if (!table::contains(&providers.providers, user_addr)) {
            return false
        };
        let user_providers = table::borrow(&providers.providers, user_addr);
        let collateral_type = type_info::type_of<CoinType>();
        table::contains(user_providers, collateral_type)
    }

    public(friend) fun assert_position_exists<CoinType>(
        user_addr: address
    ) acquires UserPositions {
        let positions = borrow_global<UserPositions>(@cdp);
        assert!(table::contains(&positions.positions, user_addr), events::err_no_position_exists());
        let user_positions = table::borrow(&positions.positions, user_addr);
        assert!(table::contains(user_positions, type_info::type_of<CoinType>()), events::err_no_position_exists());
    }

    public(friend) fun get_position_data<CoinType>(
        user_addr: address
    ): (u64, u64) acquires UserPositions {
        let positions = borrow_global<UserPositions>(@cdp);
        let user_positions = table::borrow(&positions.positions, user_addr);
        let position = table::borrow(user_positions, type_info::type_of<CoinType>());
        (position.collateral_amount, position.debt_amount)
    }

    // public(friend) fun get_collateral_ratio(coll:u64,debt:u64,price:u64):(u64) {

    //     if (debt == 0) {
    //         return 0
    //     };
    //     // Calculate collateral value (collateral_amount * price)
    //     let collateral_value = ((coll as u128) * (price as u128)) / 100000000;
    //     // Calculate ratio = (collateral_value * 10000) / debt_amount 
    //     // This gives us the ratio with 4 decimal places (e.g., 15000 = 150%)
    //     let ratio = ((collateral_value * 10000) / (debt as u128) as u64);
        
    //     ratio
    // }
}