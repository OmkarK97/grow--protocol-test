# Solido Protocol

## Overview

This protocol implements a Collateralized Debt Position (CDP) system where users can:
- Deposit supported collateral assets
- Mint CASH stablecoins against their collateral
- Manage their positions (add/remove collateral, mint/repay debt)
- Participate in liquidations and redemptions

The system maintains price stability through a combination of:
- Minimum Collateral Ratio (MCR) requirements
- Liquidation mechanisms
- Dynamic fee structures
- Redemption capabilities

## Key Features

### Collateral Management
- Multi-collateral support through generic type parameters
- Configurable parameters per collateral type
- Real-time price feeds through Supra Oracle integration
- Flexible collateral ratio requirements

### Position Operations
- Open new CDPs (Troves)
- Deposit additional collateral
- Withdraw excess collateral
- Mint additional CASH tokens
- Repay CASH debt
- Close positions

### Risk Management
- Minimum collateral ratio enforcement
- Liquidation mechanism for undercollateralized positions
- Liquidation penalties and rewards
- Protocol fee collection
- Redemption mechanism for CASH holders

### System Configuration
- Admin controls for collateral parameters
- Operation status controls (enable/disable features)
- Fee parameter management
- Price oracle updates

## Core Components

### TroveManager
The central component managing all CDP operations including:
- Collateral tracking
- Debt issuance
- Position management
- Fee collection
- Liquidation processing

### Configuration Registry
Maintains collateral-specific parameters:
- Minimum debt requirements
- Collateral ratios
- Fee rates
- Liquidation thresholds
- Operational status flags

### Price Oracle
- Integration with Supra Oracle for reliable price feeds
- Configurable price update frequency
- Price staleness checks for safety
- Fallback testing mechanism

### Events System
Comprehensive event emission for:
- Position changes
- Liquidations
- Redemptions
- System configuration updates

## Key Parameters

### Collateral Configuration
- `minimum_debt`: Minimum debt required to open a position
- `mcr`: Minimum Collateral Ratio required
- `borrow_rate`: Fee rate for borrowing
- `liquidation_reserve`: Amount set aside for potential liquidation gas costs
- `liquidation_threshold`: Ratio at which positions become liquidatable
- `liquidation_penalty`: Penalty applied during liquidations
- `redemption_fee`: Fee rate for redemptions
- `liquidation_fee_protocol`: Portion of liquidation fee sent to protocol
- `redemption_fee_gratuity`: Additional fee during redemptions

### Operational Controls
- `open_trove`: Enable/disable new position creation
- `borrow`: Enable/disable additional borrowing
- `deposit`: Enable/disable collateral deposits
- `redeem`: Enable/disable redemptions

## Core Operations

### Managing Positions

1. Open a CDP:
```move
open_trove<CoinType>(
    user,
    collateral_amount,
    cash_mint_amount
)
```
2. Deposit Additional Collateral:
```move
deposit_or_mint<CoinType>(
    user,
    collateral_deposit,
    0  // No additional minting
)
```

3. Mint Additional CASH:
```move
deposit_or_mint<CoinType>(
    user,
    0,  // No additional collateral
    cash_mint_amount
)
```

4. Repay Debt:
```move
repay_or_withdraw<CoinType>(
    user,
    0,  // No withdrawal
    repay_amount
)
```

5. Withdraw Collateral:
```move
repay_or_withdraw<CoinType>(
    user,
    withdraw_amount,
    0  // No debt repayment
)
```

### Redemption Provider Management

Users can opt in or out of being redemption providers:

```move
register_as_redemption_provider<CoinType>(
    user,
    true  // opt in (or false to opt out)
)
```

### Liquidations

Positions become eligible for liquidation when their collateral ratio falls below the liquidation threshold. Liquidators can call:

```move
liquidate<CoinType>(
    liquidator,
    user_address
)
```

Liquidation rewards include:
- Base collateral claim
- Liquidation penalty
- Protocol fee distribution

### Redemptions

CASH holders can redeem their tokens for collateral at face value (minus fees):

```move
redeem<CoinType>(
    redeemer,
    provider_addr,
    cash_amount,
    min_collateral_out
)
```

Multiple positions can be redeemed in one transaction:

```move
redeem_multiple<CoinType>(
    redeemer,
    providers,
    amounts,
    min_collateral_outs
)
```

## System Parameters

### Supra Price Oracle
- External price feeds determine collateral valuations through Supra Oracle
- Each collateral type is configured with a specific oracle ID
- Price staleness is checked to ensure fresh price data
- Admin can update oracle settings per collateral type
- Testing mode available through `set_price<CoinType>` (For Testing)

### Fee Structure
- Borrowing fees: Applied when minting CASH
- Redemption fees: Applied during redemptions
- Liquidation penalties: Applied during liquidations
- Protocol fees: Collected for protocol treasury
- Liquidation Reserve: Set aside for potential liquidation costs

## Events

The protocol emits events for all major operations:

1. Position Management:
- TroveOpenedEvent
- TroveClosedEvent
- CollateralDepositEvent
- CollateralWithdrawEvent
- DebtMintedEvent
- DebtRepaidEvent

2. Liquidations:
- TroveLiquidatedEvent

3. Redemptions:
- RedemptionEvent

4. Position Updates:
- TroveUpdatedEvent

## View Functions

Query protocol state through these view functions:

```move
get_user_position<CoinType>(user_addr): (u64, u64, bool)
get_collateral_config<CoinType>(): (u64, u64, u64, u64, u64, u64, u64, bool, u64, u64)
get_collateral_price<CoinType>(): FixedPoint32
get_total_stats<CoinType>(): (u64, u64)
is_redemption_provider(user_addr): bool
is_valid_collateral<CoinType>(): bool
get_operation_status<CoinType>(): (bool, bool, bool, bool)
```

## Deployment Instructions

### Prerequisites
- Supra Move CLI tool installed
- Access to a Supra network RPC endpoint
- Deployment account with sufficient funds

### Step 1: Publish Contract
```bash
supra move tool publish \
  --package-dir /pathtocdp/contract \
  --profile DEPLOYER_PROFILE \
  --url YOUR_RPC_ENDPOINT
```

### Step 2: Initialize Protocol
```bash
supra move tool run \
  --function-id 'DEPLOYED_ADDRESS::cdp_multi::initialize' \
  --args 'address:FEE_COLLECTOR_ADDRESS' \
  --profile DEPLOYER_PROFILE \
  --url YOUR_RPC_ENDPOINT
```

### Step 3: Register CASH Coin for Fee Collector
```bash
supra move tool run \
  --function-id 'DEPLOYED_ADDRESS::cdp_multi::register_debtToken_coin' \
  --profile FEE_COLLECTOR \
  --url YOUR_RPC_ENDPOINT
```

### Step 4: Add Collateral Support
For each collateral type, execute:

```bash
supra move tool run \
  --function-id 'DEPLOYED_ADDRESS::cdp_multi::add_collateral' \
  --type-args 'COLLATERAL_ADDRESS::MODULE::TYPE' \
  --args \
    'u64:MINIMUM_DEBT' \
    'u64:MCR' \
    'u64:BORROW_RATE' \
    'u64:LIQUIDATION_RESERVE' \
    'u64:LIQUIDATION_THRESHOLD' \
    'u64:LIQUIDATION_PENALTY' \
    'u64:REDEMPTION_FEE' \
    'u8:DECIMALS' \
    'u64:LIQUIDATION_FEE_PROTOCOL' \
    'u64:REDEMPTION_FEE_GRATUITY' \
    'u32:SUPRA_ORACLE_ID' \
    'u64:MAX_PRICE_AGE' \
  --profile DEPLOYER_PROFILE \
  --url YOUR_RPC_ENDPOINT
```

### Step 5: Set Initial Collateral Prices (Not required if using Supra Oracle)
For each collateral type:

```bash
supra move tool run \
  --function-id 'DEPLOYED_ADDRESS::price_oracle::set_price' \
  --type-args 'COLLATERAL_ADDRESS::MODULE::TYPE' \
  --args 'u64:INITIAL_PRICE' \
  --profile DEPLOYER_PROFILE \
  --url YOUR_RPC_ENDPOINT
```

### Step 6: Register Collateral Coins for Fee Collector
For each collateral type:

```bash
supra move tool run \
  --function-id 'DEPLOYED_ADDRESS::cdp_multi::register_collateral_coin' \
  --type-args 'COLLATERAL_ADDRESS::MODULE::TYPE' \
  --profile FEE_COLLECTOR \
  --url YOUR_RPC_ENDPOINT
```

### Example Configuration Values

#### Sample Collateral Parameters
- Minimum Debt: 2000000000
- MCR: 12500 (125%)
- Borrow Rate: 200 (2%)
- Liquidation Reserve: 200000000
- Liquidation Threshold: 11500 (115%)
- Liquidation Penalty: 1000 (10%)
- Redemption Fee: 50 (0.5%)
- Decimals: 8
- Liquidation Fee Protocol: 1000 (10%)
- Redemption Fee Gratuity: 100 (1%)
- Oracle ID: Supra Oracle pair ID for the collateral
- Price Age: Maximum allowed staleness of price in seconds (e.g., 900 for 15 minutes)

### Important Notes
1. Replace placeholders (DEPLOYED_ADDRESS, COLLATERAL_ADDRESS, etc.) with actual values
2. Ensure all accounts have sufficient funds for transactions
3. Verify Supra Oracle IDs are correctly configured for each collateral type
4. Test deployment on testnet before mainnet
5. Keep deployment keys secure
