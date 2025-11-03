module cdp::enhanced_price_oracle {
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::table::{Self, Table};
    use std::fixed_point32::{Self, FixedPoint32};
    use supra_framework::timestamp;
    use std::signer;
    use cdp::events;
    use cdp::price_oracle; // Use existing oracle as fallback
    use supra_oracle::supra_oracle_storage;
    use std::math128;

    friend cdp::cdp_multi;

    const PRICE_PRECISION: u64 = 100000000; // 8 decimals - SAME AS ORIGINAL
    const MAX_PRICE_THRESHOLD: u64 = 1000000000000000000; // $10M max price - SAME AS ORIGINAL
    
    const PAIR_TYPE_DIRECT_USD: u8 = 0;      // Direct USD price (BTC_USDT, ETH_USDT)
    const PAIR_TYPE_PRIMARY_RATE: u8 = 1;    // Primary rate (stSUPRA_SUPRA)

    struct EnhancedOracleInfo has store, drop {
        price: FixedPoint32,              
        oracle_id: u32,                  
        price_age: u64,                  // 900 seconds 15 minutes
        pair_type: u8,                   // NEW - 0 = direct USD, 1 = primary rate
        base_oracle_id: u32,             // NEW - For primary rates, the base asset's USD oracle
    }

    struct EnhancedPriceOracle has key {
        oracles: Table<TypeInfo, EnhancedOracleInfo>,
    }

    public entry fun initialize_enhanced_oracle(admin: &signer) {
        assert!(signer::address_of(admin) == @cdp, events::err_not_admin());
        assert!(!exists<EnhancedPriceOracle>(@cdp), events::err_already_initialized());
        
        move_to(admin, EnhancedPriceOracle {
            oracles: table::new()
        });
    }

    // Main price getter - tries enhanced oracle first, falls back to legacy
    public fun get_price<CoinType>(): FixedPoint32 acquires EnhancedPriceOracle {
        // Check if enhanced oracle exists first
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            // Fall back to legacy oracle if enhanced oracle not initialized
            return price_oracle::get_price<CoinType>()
        };
        
        let enhanced_oracle = borrow_global_mut<EnhancedPriceOracle>(@cdp);
        
        if (table::contains(&enhanced_oracle.oracles, type_info::type_of<CoinType>())) {
            // Use enhanced oracle
            let oracle_info = table::borrow_mut(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>());
            get_enhanced_price(oracle_info)
        } else {
            // Fall back to legacy oracle
            price_oracle::get_price<CoinType>()
        }
    }

    fun get_enhanced_price(oracle_info: &EnhancedOracleInfo): FixedPoint32 {
        if (oracle_info.pair_type == PAIR_TYPE_DIRECT_USD) {
            // Direct USD pair
            
            /*Comment out this while testing */  
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

            /* Comment out this while not testing  */
            // oracle_info.price
            
        } else if (oracle_info.pair_type == PAIR_TYPE_PRIMARY_RATE) {
            // Primary rate pair
            get_primary_rate_usd_price(oracle_info)
        } else {
            assert!(false, events::err_invalid_price());
            fixed_point32::create_from_rational(0, PRICE_PRECISION) // Never reached
        }
    }

    fun get_primary_rate_usd_price(oracle_info: &EnhancedOracleInfo): FixedPoint32 {
        // Get the primary rate (e.g., stSUPRA/SUPRA ratio)
        let (rate, rate_timestamp_ms) = get_price_from_supra(oracle_info.oracle_id);
        
        // Get the base asset's USD price (e.g., SUPRA/USDT)
        let (base_usd_price, base_timestamp_ms) = get_price_from_supra(oracle_info.base_oracle_id);
        
        // Validate timestamps
        validate_price_freshness(rate_timestamp_ms, oracle_info.price_age);
        validate_price_freshness(base_timestamp_ms, oracle_info.price_age);
        
        // Calculate USD price: rate * base_usd_price
        let rate_raw = fixed_point32::get_raw_value(rate);
        let base_raw = fixed_point32::get_raw_value(base_usd_price);
        
        // Multiply using u128 to avoid overflow, then shift back
        let result_raw = ((rate_raw as u128) * (base_raw as u128)) >> 32;
        let final_price = fixed_point32::create_from_raw_value((result_raw as u64));
        
        // SAME validation as 
        let price_value = fixed_point32::multiply_u64(PRICE_PRECISION, final_price);
        assert!(price_value > 0, events::err_invalid_price()); 
        assert!(price_value < MAX_PRICE_THRESHOLD, events::err_invalid_price());
        
        final_price
    }

    fun validate_price_freshness(timestamp_ms: u64, max_age: u64) {
        let timestamp_sec = timestamp_ms / 1000;
        let current_time = timestamp::now_seconds();
        assert!(current_time - timestamp_sec <= max_age, events::err_price_stale());
    }

    fun get_price_from_supra(pair_id: u32): (FixedPoint32, u64) {
        let (price, decimals, timestamp, _) = supra_oracle_storage::get_price(pair_id);
        let decimals_u8 = (decimals as u8);
        
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

    // Set direct USD oracle
    public(friend) fun set_direct_usd_oracle<CoinType>(
        oracle_id: u32,
        price_age: u64
    ) acquires EnhancedPriceOracle {
        
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            abort events::err_oracle_not_found()
        };
        
        let enhanced_oracle = borrow_global_mut<EnhancedPriceOracle>(@cdp);
        

        if (!table::contains(&enhanced_oracle.oracles, type_info::type_of<CoinType>())) {
            let oracle_info = EnhancedOracleInfo {
                price: fixed_point32::create_from_rational(0, PRICE_PRECISION), 
                oracle_id,
                price_age,
                pair_type: PAIR_TYPE_DIRECT_USD,
                base_oracle_id: 0,
            };
            table::add(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>(), oracle_info);
        } else {
            let oracle_info = table::borrow_mut(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>());
            oracle_info.oracle_id = oracle_id;
            oracle_info.price_age = price_age;
            // Keep existing pair_type and base_oracle_id
        };
    }

    // Set primary rate oracle (NEW functionality)
    public(friend) fun set_primary_rate_oracle<CoinType>(
        rate_oracle_id: u32,
        base_usd_oracle_id: u32,
        price_age: u64
    ) acquires EnhancedPriceOracle {
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            abort events::err_oracle_not_found()
        };
        
        let enhanced_oracle = borrow_global_mut<EnhancedPriceOracle>(@cdp);
        
        let oracle_info = EnhancedOracleInfo {
            price: fixed_point32::create_from_rational(0, PRICE_PRECISION), 
            oracle_id: rate_oracle_id,
            price_age,
            pair_type: PAIR_TYPE_PRIMARY_RATE,
            base_oracle_id: base_usd_oracle_id,
        };
        
        table::upsert(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>(), oracle_info);
    }

    // Update oracle 
    public(friend) fun update_oracle<CoinType>(
        new_oracle_id: u32,
        new_price_age: u64
    ) acquires EnhancedPriceOracle {
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            abort events::err_oracle_not_found()
        };
        
        let enhanced_oracle = borrow_global_mut<EnhancedPriceOracle>(@cdp);
        
        // Verify oracle exists for this coin type 
        assert!(
            table::contains(&enhanced_oracle.oracles, type_info::type_of<CoinType>()), 
            events::err_oracle_not_found()
        );
        
        // Update oracle 
        let oracle_info = table::borrow_mut(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>());
        oracle_info.oracle_id = new_oracle_id;
        oracle_info.price_age = new_price_age;
    }

    // Remove enhanced oracle 
    public(friend) fun remove_enhanced_oracle<CoinType>() acquires EnhancedPriceOracle {
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            return // Nothing to remove
        };
        
        let enhanced_oracle = borrow_global_mut<EnhancedPriceOracle>(@cdp);
        if (table::contains(&enhanced_oracle.oracles, type_info::type_of<CoinType>())) {
            let _ = table::remove(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>());
        };
    }


    #[view]
    public fun get_price_raw<CoinType>(): u64 acquires EnhancedPriceOracle {
        let price = get_price<CoinType>();
        fixed_point32::multiply_u64(PRICE_PRECISION, price)
    }

    // mirrors  get_oracle_id
    #[view]
    public fun get_oracle_id<CoinType>(): u32 acquires EnhancedPriceOracle {
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            return price_oracle::get_oracle_id<CoinType>()
        };
        
        let enhanced_oracle = borrow_global<EnhancedPriceOracle>(@cdp);
        if (table::contains(&enhanced_oracle.oracles, type_info::type_of<CoinType>())) {
            table::borrow(&enhanced_oracle.oracles, type_info::type_of<CoinType>()).oracle_id
        } else {
            price_oracle::get_oracle_id<CoinType>()
        }
    }

    // For testing only 
    public(friend) fun set_price<CoinType>(
        price: u64
    ) acquires EnhancedPriceOracle {
        if (!exists<EnhancedPriceOracle>(@cdp)) {
            abort events::err_oracle_not_found()
        };
        
        let enhanced_oracle = borrow_global_mut<EnhancedPriceOracle>(@cdp);
        assert!(table::contains(&enhanced_oracle.oracles, type_info::type_of<CoinType>()), 1);
        
        let oracle_info = table::borrow_mut(&mut enhanced_oracle.oracles, type_info::type_of<CoinType>());
        oracle_info.price = fixed_point32::create_from_rational(price, PRICE_PRECISION);
    }
}