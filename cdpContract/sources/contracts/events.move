module cdp::events {
    use aptos_std::type_info::TypeInfo;
    use supra_framework::event;
    friend cdp::cdp_multi;
    friend cdp::config;
    friend cdp::price_oracle;
    friend cdp::positions;
    friend cdp::enhanced_price_oracle;

    // Error codes
    const ERR_BELOW_MINIMUM_DEBT: u64 = 1;
    const ERR_ALREADY_INITIALIZED: u64 = 2;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 3;
    const ERR_UNSUPPORTED_COLLATERAL: u64 = 4;
    const ERR_NO_POSITION_EXISTS: u64 = 5;
    const ERR_INSUFFICIENT_COLLATERAL_BALANCE: u64 = 6;
    const ERR_INSUFFICIENT_DEBT_BALANCE: u64 = 7;
    const ERR_POSITION_ALREADY_EXISTS: u64 = 8;
    const ERR_CANNOT_LIQUIDATE: u64 = 9;
    const ERR_NOT_ADMIN: u64 = 10;
    const ERR_COLLATERAL_DISABLED: u64 = 11;
    const ERR_INVALID_ARRAY_LENGTH: u64 = 12;
    const ERR_NOT_REDEMPTION_PROVIDER: u64 = 13;
    const ERR_COIN_NOT_INITIALIZED: u64 = 14;
    const ERR_OPERATION_DISABLED: u64 = 15;
    const ERR_INVALID_LIQUIDATION: u64 = 16;
    const ERR_ORACLE_NOT_FOUND: u64 = 17;
    const ERR_PRICE_STALE: u64 = 18;
    const ERR_SELF_LIQUIDATION: u64 = 19;
    const ERR_INVALID_DEBT_AMOUNT: u64 = 20;
    const ERR_INVALID_PRICE: u64 = 21;
    const ERR_FEE_TOO_SMALL: u64 = 22;
    const ERR_SLIPPAGE_EXCEEDED: u64 = 23;
    const ERR_POSITION_TOO_SMALL_FOR_PARTIAL_LIQUIDATION: u64 = 24;
    const ERR_LIQUIDATION_AMOUNT_TOO_SMALL: u64 = 25;

    const TROVE_ACTION_OPEN: u8 = 0;
    const TROVE_ACTION_ADJUST: u8 = 1;
    const TROVE_ACTION_REDEEM: u8 = 2;
    const TROVE_ACTION_LIQUIDATE: u8 = 3;
    const TROVE_ACTION_CLOSE: u8 = 4;

   

    #[event]
    struct TroveOpenedEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        collateral_amount: u64,
        debt_amount: u64,
        timestamp: u64
    }

    // event for trove closed
    #[event]
    struct TroveClosedEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        collateral_returned: u64,
        debt_repaid: u64,
        timestamp: u64
    }

    // event for trove liquidated
    #[event]
    struct TroveLiquidatedEvent has drop, store {
        user: address,
        liquidator: address,
        collateral_type: TypeInfo,
        collateral_liquidated: u64,
        debt_liquidated: u64,
        liquidator_reward: u64,
        protocol_fee: u64,
        user_refund: u64,
        timestamp: u64,
    }

    // event for redemption
    #[event]
    struct RedemptionEvent has drop, store {
        redeemer: address,
        provider: address,
        collateral_type: TypeInfo,
        collateral_redeemed: u64,
        debt_redeemed: u64,
        fee_paid: u64,
        timestamp: u64
    }

    #[event]
    struct CollateralDepositEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        timestamp: u64
    }

    #[event]
    struct CollateralWithdrawEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        timestamp: u64
    }

    #[event]
    struct DebtMintedEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        fee: u64,
        timestamp: u64
    }

    #[event]
    struct DebtRepaidEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        timestamp: u64
    }

    #[event]
    struct TroveUpdatedEvent has drop, store {
        user: address,
        collateral_type: TypeInfo,
        collateral_amount: u64,
        debt_amount: u64,
        timestamp: u64,
        block_number: u64,
        action: u8
    }

    #[event]
    struct OracleUpdatedEvent has drop, store {
        new_oracle_id: u32,
        new_price_age: u64
    }

    #[event]
    struct OperationStatusUpdatedEvent has drop, store {
        open_trove: bool,
        borrow: bool,
        deposit: bool,  
        redeem: bool
    }

    #[event]
    struct FeeCollectorUpdatedEvent has drop, store {
        new_fee_collector: address
    }

    #[event]
    struct CollateralConfigUpdatedEvent has drop, store {
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        redemption_fee: u64,
        enabled: bool,
        liquidation_fee_protocol: u64,
        redemption_fee_gratuity: u64
    }

     //   functions to access error codes
    public(friend) fun err_below_minimum_debt(): u64 { ERR_BELOW_MINIMUM_DEBT }
    public(friend) fun err_already_initialized(): u64 { ERR_ALREADY_INITIALIZED }
    public(friend) fun err_insufficient_collateral(): u64 { ERR_INSUFFICIENT_COLLATERAL }
    public(friend) fun err_unsupported_collateral(): u64 { ERR_UNSUPPORTED_COLLATERAL }
    public(friend) fun err_no_position_exists(): u64 { ERR_NO_POSITION_EXISTS }
    public(friend) fun err_insufficient_collateral_balance(): u64 { ERR_INSUFFICIENT_COLLATERAL_BALANCE }
    public(friend) fun err_insufficient_debt_balance(): u64 { ERR_INSUFFICIENT_DEBT_BALANCE }
    public(friend) fun err_position_already_exists(): u64 { ERR_POSITION_ALREADY_EXISTS }
    public(friend) fun err_cannot_liquidate(): u64 { ERR_CANNOT_LIQUIDATE }
    public(friend) fun err_not_admin(): u64 { ERR_NOT_ADMIN }
    public(friend) fun err_collateral_disabled(): u64 { ERR_COLLATERAL_DISABLED }
    public(friend) fun err_invalid_array_length(): u64 { ERR_INVALID_ARRAY_LENGTH }
    public(friend) fun err_not_redemption_provider(): u64 { ERR_NOT_REDEMPTION_PROVIDER }
    public(friend) fun err_coin_not_initialized(): u64 { ERR_COIN_NOT_INITIALIZED }
    public(friend) fun err_operation_disabled(): u64 { ERR_OPERATION_DISABLED }
    public(friend) fun err_invalid_liquidation(): u64 { ERR_INVALID_LIQUIDATION }
    public(friend) fun err_oracle_not_found(): u64 { ERR_ORACLE_NOT_FOUND }
    public(friend) fun err_price_stale(): u64 { ERR_PRICE_STALE }
    public(friend) fun err_self_liquidation(): u64 { ERR_SELF_LIQUIDATION }   
    public(friend) fun err_invalid_debt_amount(): u64 { ERR_INVALID_DEBT_AMOUNT }
    public(friend) fun err_invalid_price(): u64 { ERR_INVALID_PRICE }
    public(friend) fun err_fee_too_small(): u64 { ERR_FEE_TOO_SMALL }
    public(friend) fun err_slippage_exceeded(): u64 { ERR_SLIPPAGE_EXCEEDED }
    public(friend) fun err_position_too_small_for_partial_liquidation(): u64 { ERR_POSITION_TOO_SMALL_FOR_PARTIAL_LIQUIDATION }
    public(friend) fun err_liquidation_amount_too_small(): u64 { ERR_LIQUIDATION_AMOUNT_TOO_SMALL }

    //  functions to access trove actions
    public(friend) fun trove_action_open(): u8 { TROVE_ACTION_OPEN }
    public(friend) fun trove_action_adjust(): u8 { TROVE_ACTION_ADJUST }
    public(friend) fun trove_action_redeem(): u8 { TROVE_ACTION_REDEEM }
    public(friend) fun trove_action_liquidate(): u8 { TROVE_ACTION_LIQUIDATE }
    public(friend) fun trove_action_close(): u8 { TROVE_ACTION_CLOSE }



    //  functions to emit events

    public(friend) fun emit_trove_closed(
        user: address,
        collateral_type: TypeInfo,
        collateral_returned: u64,
        debt_repaid: u64,
        timestamp: u64
    ) {
        event::emit(TroveClosedEvent {
            user,
            collateral_type,
            collateral_returned,
            debt_repaid,
            timestamp
        });
    }

    public(friend) fun emit_trove_liquidated(
        user: address,
        liquidator: address,
        collateral_type: TypeInfo,
        collateral_liquidated: u64,
        debt_liquidated: u64,
        liquidator_reward: u64,
        protocol_fee: u64,
        user_refund: u64,
        timestamp: u64
    ) {
        event::emit(TroveLiquidatedEvent {  
            user,
            liquidator,
            collateral_type,
            collateral_liquidated,
            debt_liquidated,
            liquidator_reward,
            protocol_fee,
            user_refund,
            timestamp
        });
    }           

    public(friend) fun emit_redemption_event(
        redeemer: address,
        provider: address,
        collateral_type: TypeInfo,
        collateral_redeemed: u64,
        debt_redeemed: u64,
        fee_paid: u64,
        timestamp: u64
    ) { 
        event::emit(RedemptionEvent {
            redeemer,
            provider,
            collateral_type,
            collateral_redeemed,
            debt_redeemed,
            fee_paid,
            timestamp
        });
    }   

    public(friend) fun emit_collateral_deposit_event(
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        timestamp: u64
    ) {
        event::emit(CollateralDepositEvent {
            user,
            collateral_type,
            amount,
            timestamp
        });
    }

    public(friend) fun emit_collateral_withdraw_event(
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        timestamp: u64
    ) { 
        event::emit(CollateralWithdrawEvent {
            user,
            collateral_type,
            amount,
            timestamp
        });
    }   

    public(friend) fun emit_debt_minted_event(
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        fee: u64,
        timestamp: u64
    ) { 
        event::emit(DebtMintedEvent {
            user,
            collateral_type,
            amount,
            fee,
            timestamp
        });
    }       

    public(friend) fun emit_debt_repaid_event(
        user: address,
        collateral_type: TypeInfo,
        amount: u64,
        timestamp: u64
    ) { 
        event::emit(DebtRepaidEvent {
            user,
            collateral_type,
            amount,
            timestamp
        });
    }

    public(friend) fun emit_trove_updated_event(
        user: address,
        collateral_type: TypeInfo,
        collateral_amount: u64,
        debt_amount: u64,
        timestamp: u64,
        block_number: u64,
        action: u8
    ) {
        event::emit(TroveUpdatedEvent {
            user,
            collateral_type,
            collateral_amount,
            debt_amount,
            timestamp,
            block_number,
            action
        });
    }

    public(friend) fun emit_trove_opened(
        user: address,
        collateral_type: TypeInfo,
        collateral_amount: u64,
        debt_amount: u64,
        timestamp: u64
    ) {
        event::emit(TroveOpenedEvent {
            user,
            collateral_type,
            collateral_amount,
            debt_amount,
            timestamp
        });
    }

    public(friend) fun emit_oracle_updated_event(
        new_oracle_id: u32,
        new_price_age: u64
    ) {
        event::emit(OracleUpdatedEvent {
            new_oracle_id,
            new_price_age
        });
        }

    public(friend) fun emit_operation_status_updated_event(
        open_trove: bool,
        borrow: bool,
        deposit: bool,
        redeem: bool
    ) {
        event::emit(OperationStatusUpdatedEvent {
            open_trove,
            borrow,
            deposit,
            redeem
        });
    }   

    public(friend) fun emit_fee_collector_updated_event(
        new_fee_collector: address
    ) {
        event::emit(FeeCollectorUpdatedEvent { new_fee_collector });
    }

    public(friend) fun emit_collateral_config_updated_event(
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
        event::emit(CollateralConfigUpdatedEvent {
            minimum_debt,
            mcr,
            borrow_rate,
            liquidation_threshold,
            liquidation_penalty,
            redemption_fee,
            enabled,
            liquidation_fee_protocol,
            redemption_fee_gratuity
        });
    }
}   