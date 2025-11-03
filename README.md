# Supra Vault Smart Contract

A flexible, ERC-4626 style vault implementation for the Aptos/Move ecosystem with Supra Framework integration.

## Overview

This smart contract implements a yield-generating vault system with configurable strategies, delayed withdrawals, and performance fee mechanisms. Users can deposit assets into the vault to receive share tokens, which represent their proportional ownership of the vault's total assets.

## Features

- **Asset Management**: Secure deposit and withdrawal of assets
- **Tokenized Shares**: ERC-4626 style tokenized vault shares
- **Delayed Withdrawals**: Configurable withdrawal delay mechanism
- **Strategy Integration**: Yield generation through integrated strategies
- **Performance Fees**: Configurable fee structure for generated yield
- **Admin Controls**: Pause functionality, TVL limits, and emergency controls

## Core Components

- **Vault Core**: Main vault implementation with deposit/withdraw functionality
- **Strategy Core**: Integrated yield generation strategies
- **Share Token**: Represents ownership stake in the vault
- **Delayed Withdrawals**: Time-locked withdrawal mechanism

## Key Functions

### User Operations

- `deposit<AssetType>`: Deposit assets into the vault
- `withdraw<AssetType>`: Withdraw assets from the vault
- `redeem<AssetType>`: Redeem share tokens for assets
- `claim_withdrawal<AssetType>`: Claim assets after withdrawal delay period

### Admin Operations

- `initialize<AssetType>`: Initialize the vault for a specific asset type
- `harvest<AssetType, CollateralType>`: Generate yield from strategy
- `pause/unpause`: Emergency pause/unpause of vault operations
- `set_tvl_limit`: Set maximum Total Value Locked
- `set_withdraw_delay`: Configure withdrawal delay period
- `set_performance_fee`: Set performance fee percentage

## Architecture

The vault contract follows a modular design:

1. **Main Vault Module**: Handles deposits, withdrawals, and share token management
2. **Strategy Module**: Implements yield generation strategies
3. **Resource Accounts**: Separate accounts for vault assets and delayed withdrawals

## Usage Example

```move
// Initialize a vault for APT coins
vault::vault_core::initialize<AptosCoin>(
    admin,
    string::utf8(b"Supra APT Vault"),
    string::utf8(b"sAPT"),
    8,
    fee_recipient_address
);

// Deposit assets
vault::vault_core::deposit<AptosCoin>(user, 1000000);

// Withdraw assets
vault::vault_core::withdraw<AptosCoin>(user, 500000);

// Check balance
let shares = coin::balance<vault::vault_core::VaultShare>(user_address);
```

## Security Considerations

- Module has access controls for admin functions
- Withdrawal delays protect against flash loan attacks
- Extensive error handling to prevent common vulnerabilities

## Development

### Prerequisites

- Supra CLI
- Move compiler

### Testing

```bash
supra move tool test --package-dir /supra/configs/move_workspace/vaultcontract
```

## License

[MIT License] 