# Covered European-Style Options Smart Contract

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue.svg)
![Chainlink](https://img.shields.io/badge/Chainlink-Price_Feeds-375BD2.svg)
![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-Security-4E5EE4.svg)
![Foundry](https://img.shields.io/badge/Foundry-Forge-FF6C37.svg)

A decentralized smart contract for trading Covered European-Style Options on Ethereum, using **ETH** as the underlying asset and **DAI** for premiums and strike prices. This contract enables users to write, buy, exercise, and cancel options in a secure, trustless manner, leveraging Chainlink for real-time price feeds and OpenZeppelin for robust security. Built and tested with Foundry (Forge) for a streamlined development experience.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Contract Architecture](#contract-architecture)
- [Security Considerations](#security-considerations)
- [Testing](#testing)
- [Future Enhancements](#future-enhancements)
- [License](#license)

---

## Overview

This smart contract facilitates Covered European-Style Options trading on Ethereum, supporting:

- **Covered Calls**: Writers lock ETH as collateral, allowing buyers to purchase at the strike price.
- **Cash-Secured Puts**: Writers provide ETH collateral to cover potential purchases at the strike price.

Designed for financial clients, and recruiters evaluating blockchain expertise, this contract offers a secure platform for options trading, with comprehensive testing via Foundry.

---

## Features

- **Write Options:** Create call or put options with ETH collateral.
- **Buy Options:** Purchase options by paying premiums in DAI.
- **Exercise Options:** Execute in-the-money options at expiration.
- **Cancel Options:** Reclaim collateral from expired, out-of-the-money options.
- **Real-Time Pricing:** Chainlink price feeds ensure accurate DAI/ETH rates.
- **Security:** OpenZeppelin’s `ReentrancyGuard`, `Ownable`, and `Pausable` enhance safety.

---

## Prerequisites

- **Wallet:** A cryptocurrency wallet (e.g., MetaMask) with ETH and DAI.
- **Network:** Access to an Ethereum network (mainnet or testnet like Sepolia).
- **Tools:** Foundry installed (`forge`, `cast`, `anvil`). See [Foundry Installation](https://book.getfoundry.sh/getting-started/installation).
- **Solidity:** Version 0.8.28 or compatible.

---

## Installation

### Clone the Repository

```bash
git clone https://github.com/rocknwa/European-Style-Options.git
cd European-Style-Options
```
 

### Install Foundry

Ensure Foundry is installed:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install Dependencies

Install external dependencies (e.g., OpenZeppelin, Chainlink):

```bash
forge install
```

Dependencies are defined in `lib/` and include:

- `chainlink-brownie-contracts`
- `openzeppelin-contracts`
- `forge-std`

### Build the Project

Compile the contracts:

```bash
forge build
```

---

## Usage

Below are examples of interacting with the contract using Solidity or Foundry’s `cast` tool. Ensure your wallet has ETH and DAI, and approve DAI spending where required.

### Deploy the Contract

#### Set Environment Variables

Create a `.env` file in the project root:

```env
PRIVATE_KEY=your-private-key
DAI_ADDRESS=0x6B175474E89094C44Da98b954EedeAC495271d0F
PRICE_FEED_ADDRESS=0x773616E4d11A78F511299002da57A0a94577F1f4
ETH_RPC_URL=https://your-ethereum-node-url
```
> Adjust addresses for testnets (e.g., Sepolia) if needed.

#### Deploy Using Forge

```bash
forge script script/DeployOptions.s.sol --rpc-url $ETH_RPC_URL --broadcast
```

Output will display the deployed contract address.

---

### Writing a Call Option

Lock ETH collateral to offer a call option:

```solidity
uint256 amount = 1e15; // 0.001 ETH
uint256 premiumDue = 1e17; // 0.1 DAI
uint256 daysToExpiry = 7;
uint256 marketPrice = options.getPriceFeed(1e18); // Current DAI/ETH price
uint256 requiredCollateral = (amount * 1e18) / marketPrice;

options.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);
```

**Using cast:**

```bash
cast send <contract-address> "writeCallOption(uint256,uint256,uint256,uint256)" 1000000000000000 <market-price> 100000000000000000 7 --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --value <required-collateral>
```
> Replace `<market-price>` and `<required-collateral>` with actual values from `getPriceFeed`.

---

### Buying a Call Option

Pay the premium in DAI to buy an option:

```solidity
uint256 optionId = 0;
options.buyCallOption(optionId);
```

**Using cast:**

```bash
cast send <contract-address> "buyCallOption(uint256)" 0 --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

> **Note:** Approve DAI spending first:

```bash
cast send <dai-address> "approve(address,uint256)" <contract-address> <premium-amount> --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

---

### Exercising a Call Option

Exercise an in-the-money call option after expiration:

```solidity
uint256 optionId = 0;
options.exerciseCallOption(optionId);
```

**Using cast:**

```bash
cast send <contract-address> "exerciseCallOption(uint256)" 0 --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

> **Note:** Approve DAI for the strike price.

---

### Canceling an Expired Option

Reclaim collateral from an expired, worthless option:

```solidity
uint256 optionId = 0;
options.optionExpiresWorthless(optionId);
options.retrieveExpiredFunds(optionId);
```

**Using cast:**

```bash
cast send <contract-address> "optionExpiresWorthless(uint256)" 0 --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
cast send <contract-address> "retrieveExpiredFunds(uint256)" 0 --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

---

## Contract Architecture

The contract is designed for clarity, security, and maintainability:

### Imports

- **Chainlink:** `AggregatorV3Interface` for DAI/ETH price feeds.
- **OpenZeppelin:** `ReentrancyGuard`, `Ownable`, `Pausable`, `SafeERC20`.
- **Forge-std:** Utilities for testing and deployment.

### Key Structures

- **Option:** Stores writer, buyer, amount, strike, premium, expiration, collateral, state, and type.

### Mappings

- `s_optionIdToOption`: Option ID to Option details.
- `s_tradersPosition`: Trader address to their option IDs.

### Functions

- `writeCallOption` / `writePutOption`: Create options with collateral.
- `buyCallOption` / `buyPutOption`: Purchase options with DAI.
- `exerciseCallOption` / `exercisePutOption`: Execute options.
- `optionExpiresWorthless`: Cancel worthless options.
- `retrieveExpiredFunds`: Reclaim collateral.

---

## Security Considerations

- **Reentrancy Protection:** `nonReentrant` modifier prevents reentrancy attacks.
- **Pausable:** Owner can pause operations in emergencies.
- **Input Validation:** Rejects zero inputs, invalid option states, and incorrect collateral.
- **Price Feed Safety:** Validates Chainlink data for freshness and positivity.
- **Risks:** *Unaudited code; test thoroughly before mainnet deployment.*

---

## Testing

The contract includes a comprehensive test suite using Foundry:

### Scenarios Tested

- Writing, buying, exercising, and canceling call/put options.
- Edge cases (e.g., zero inputs, invalid IDs, stale price feeds).
- Security checks (e.g., unauthorized access, transfer failures).

### Run Tests

```bash
forge test
```

For verbose output:

```bash
forge test -vvv
```

---

## License

This project is licensed under the MIT License ([LICENSE](LICENSE)).

---

## Author

**Therock Ani**  
Email: anitherock44@gmail.com