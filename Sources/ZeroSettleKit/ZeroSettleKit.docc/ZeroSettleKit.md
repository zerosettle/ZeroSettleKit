# ``ZeroSettleKit``

Seamless stablecoin settlements for mobile games and apps.

## Overview

ZeroSettleKit is a Swift framework that enables mobile games and applications to easily integrate Web3 payment functionality. It provides a complete solution for converting fiat payments to stablecoins, managing embedded wallets, and distributing payouts to multiple recipients.

Built specifically for iOS developers who want to add blockchain-based payments without dealing with Web3 complexity, ZeroSettleKit handles all the heavy lifting:

- **Phone Number Authentication** - Users authenticate with their phone number via Privy
- **Embedded Wallets** - Secure Solana wallets are automatically created and managed
- **Fiat → Crypto** - Apple Pay payments are converted to USDC via Coinbase Commerce
- **Multi-Recipient Payouts** - Automatically split payments across multiple wallets based on configurable payout tables
- **Multi-Chain Support** - Support for Solana, Base, Ethereum, and other EVM chains

## Topics

### Essentials

- <doc:Overview>
- <doc:GettingStarted>
- <doc:Quickstart>

### Core Concepts

- <doc:Architecture>
- <doc:Authentication>
- <doc:PaymentProcessing>
- <doc:PayoutTables>

### Advanced

- <doc:Security>
- <doc:CustomPaymentProcessors>
- <doc:MultiChainSupport>

### API Reference

- ``ZeroSettleManager``
- ``AuthenticationManager``
- ``PaymentProcessor``
- ``ZeroSettleDelegate``
- ``ZeroSettleConfig``
- ``ZeroSettlePayoutTable``
