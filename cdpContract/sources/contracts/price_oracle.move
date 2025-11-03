module cdp::price_oracle {
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::table::{Self, Table};
    use std::fixed_point32::{Self, FixedPoint32};
    use supra_framework::timestamp;
    friend cdp::cdp_multi;
    friend cdp::config;
    use cdp::events;
    use supra_oracle::supra_oracle_storage;
    use std::math128;
    const PRICE_PRECISION: u64 = 100000000; // 8 decimals
    const MAX_PRICE_THRESHOLD: u64 = 1000000000000000000; // $10M max price
    


    struct OracleInfo has store {
        price: FixedPoint32,
        oracle_id: u32,
        price_age: u64//900 seconds 15 minutes
    }

    struct CollateralPriceOracle has key {
        oracles: Table<TypeInfo, OracleInfo>,
    }

    public(friend) fun initialize(admin: &signer) {
        move_to(admin, CollateralPriceOracle {
            oracles: table::new()
        });
    }


    public fun get_price<CoinType>(): FixedPoint32 acquires CollateralPriceOracle {
        let price_oracle = borrow_global_mut<CollateralPriceOracle>(@cdp);
        assert!(
            table::contains(&price_oracle.oracles, type_info::type_of<CoinType>()), 
            events::err_oracle_not_found()
        );
        
        let oracle_info = table::borrow_mut(&mut price_oracle.oracles, type_info::type_of<CoinType>());
        
        /*Comment out this while testing  */  
        let (new_price, oracle_timestamp_ms) = get_price_from_supra(oracle_info.oracle_id);
        let oracle_timestamp_sec = oracle_timestamp_ms / 1000;
        let current_time = timestamp::now_seconds();
        assert!(
            current_time - oracle_timestamp_sec <= oracle_info.price_age,
            events::err_price_stale()
        );
        let price_value = fixed_point32::multiply_u64(PRICE_PRECISION, new_price);
        assert!(price_value > 0, events::err_invalid_price()); 
        assert!(price_value < MAX_PRICE_THRESHOLD, events::err_invalid_price());
        new_price

        /* Comment out this while not testing */
        // oracle_info.price
    }

    // Admin function to set oracle id for a coin type
    public(friend) fun set_oracle<CoinType>(
        oracle_id: u32,
        price_age: u64
    ) acquires CollateralPriceOracle {
        let price_oracle = borrow_global_mut<CollateralPriceOracle>(@cdp);
        
        if (!table::contains(&price_oracle.oracles, type_info::type_of<CoinType>())) {
            let oracle_info = OracleInfo {
                price: fixed_point32::create_from_rational(0, PRICE_PRECISION),
                oracle_id,
                price_age
            };
            table::add(&mut price_oracle.oracles, type_info::type_of<CoinType>(), oracle_info);
        } else {
            let oracle_info = table::borrow_mut(&mut price_oracle.oracles, type_info::type_of<CoinType>());
            oracle_info.oracle_id = oracle_id;
            oracle_info.price_age = price_age;
        };
    }

    public(friend) fun update_oracle<CoinType>(
        new_oracle_id: u32,
        new_price_age: u64
    ) acquires CollateralPriceOracle {
    
        let price_oracle = borrow_global_mut<CollateralPriceOracle>(@cdp);
        
        // Verify oracle exists for this coin type
        assert!(
            table::contains(&price_oracle.oracles, type_info::type_of<CoinType>()), 
            events::err_oracle_not_found()
        );
        
        // Update oracle 
        let oracle_info = table::borrow_mut(&mut price_oracle.oracles, type_info::type_of<CoinType>());
        oracle_info.oracle_id = new_oracle_id;
        oracle_info.price_age = new_price_age;
    }

    #[view]
    public fun get_price_raw<CoinType>(): u64 acquires CollateralPriceOracle {
        let price = get_price<CoinType>();
        fixed_point32::multiply_u64(PRICE_PRECISION, price)
    }

    #[view]
    public fun get_oracle_id<CoinType>(): u32 acquires CollateralPriceOracle {
        let price_oracle = borrow_global<CollateralPriceOracle>(@cdp);
        assert!(table::contains(&price_oracle.oracles, type_info::type_of<CoinType>()), 1);
        table::borrow(&price_oracle.oracles, type_info::type_of<CoinType>()).oracle_id
    }


    fun get_price_from_supra(pair_id: u32): (FixedPoint32, u64) {
        let (price, decimals, timestamp, _) = supra_oracle_storage::get_price(pair_id);
        let decimals_u8 = (decimals as u8);
        
        // First adjust the price based on decimals
        let price_adjusted = if (decimals_u8 > 8) {
            // Need to reduce precision - first divide by enough to fit in u64
            let total_reduction = ((decimals_u8 - 8) as u128);
            price / math128::pow(10u128, total_reduction)
        } else if (decimals_u8 < 8) {
            // Need to increase precision
            let exp = ((8 - decimals_u8) as u128);
            price * math128::pow(10u128, exp)
        } else {
            price
        };
        
        // Now safe to cast to u64 since we've adjusted the decimals
        let price_u64 = (price_adjusted as u64);
        
        (fixed_point32::create_from_rational(price_u64, PRICE_PRECISION), timestamp)
    }

    // For testing only
    public(friend) fun set_price<CoinType>(
        price: u64
    ) acquires CollateralPriceOracle {
        let price_oracle = borrow_global_mut<CollateralPriceOracle>(@cdp);
        assert!(table::contains(&price_oracle.oracles, type_info::type_of<CoinType>()), 1);
        
        let oracle_info = table::borrow_mut(&mut price_oracle.oracles, type_info::type_of<CoinType>());
        oracle_info.price = fixed_point32::create_from_rational(price, PRICE_PRECISION);
    }

    // #[view]
    // public fun test_price_time_stamp(id: u32):(u64, u64) {
    //     let (_price, _decimals, timestamp, _) = supra_oracle_storage::get_price(id);
    //     (timestamp/1000, timestamp::now_seconds())
    // }

}