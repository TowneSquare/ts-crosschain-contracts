# TownSquare Modular Crosschain Money Market Protocol

The **TownSquare Modular Crosschain Money Market Protocol** is a modular cross-chain lending system that enables seamless liquidity sharing and efficient capital utilization across multiple blockchains.

It is built around a **centralized liquidity hub**, which serves as the main pool of assets, and multiple **spokes** — independent lending environments on different blockchains that connect to the hub through secure relayer communication.  

This architecture allows users to lend, borrow, and manage assets across chains as if they were on a single network, while maintaining the security and autonomy of each individual chain.

---

## 🧱 Contract Structure Overview

### **InterestRateCalculator**
Contains contracts responsible for defining and calculating interest rates on loans and deposits.  
These contracts model how borrowing costs evolve based on utilization and market parameters.

- `BaseInterestRate.sol` — Defines the foundational logic for interest rate calculations.  
- `LinearInterestRate.sol` — Implements a linear interest rate model, where rates increase steadily with utilization.  
- `PiecewiseInterestRate.sol` — Defines tiered interest rate behavior, with varying rates across utilization ranges.

---

### **lendingHub**
Core logic for the **Hub** — the central component that holds global liquidity, manages asset data, and coordinates cross-chain actions.

- `Hub.sol` — The Hub contract serves as the central liquidity and state management layer of the protocol.
It coordinates all cross-chain interactions with Spoke contracts, manages registered assets, handles vault accounting, liquidation logic, and ensures consistency across chains through the Wormhole bridge. 
- `AssetRegistry.sol` — Registers and maintains metadata for all supported assets and their wrapped equivalents.  
- `HubStorage.sol` & `HubState.sol` — Contain core storage variables and manage system-level state persistence.  
- `HubHelperViews.sol` — Provides read-only helper functions for querying Hub-related data.  
- `HubInterestUtilities.sol` & `HubPriceUtilities.sol` — Utility modules for interest rate and price computations.  
- `LegacyAssetRegistry.sol` — Manages the registration and configuration of assets in the lending protocol, defining parameters like collateralization ratios, liquidation limits, and interest rate calculators for each asset.

---

### **lendingSpoke/**
Houses the **Spoke** contracts, which represent user-facing components deployed on external chains.  
Each Spoke interacts with the Hub to synchronize liquidity and execute cross-chain lending operations.

- `Spoke.sol` — serves as the cross-chain entry point for user actions such as deposits, withdrawals, and borrows. It communicates with the **Hub** contract via **Wormhole messaging**, manages local token custody and optimistic finality logic, and ensures seamless cross-chain state synchronization. 
- `SpokeGetters.sol` — Provides read-only getter functions for retrieving key configuration details of the Spoke contract, such as chain IDs, hub address, and default gas settings. 
- `SpokeState.sol` — Defines and manages the **state structure** for the Spoke contract, storing essential variables like chain configuration, hub linkage, and Wormhole messaging parameters.

---

### **liquidationCalculator**
Responsible for identifying under-collateralized positions and determining liquidation parameters.

- `LiquidationCalculator.sol` — Computes health factors, thresholds, and liquidation penalties for at-risk positions.

---

### **migration/**
Provides tools to safely migrate data or configurations between protocol versions.

- `AssetRegistryMigrator.sol` — Handles migration of asset registry information from legacy contracts to new Hub versions.

---

### **priceOracle**
Defines how asset prices are fetched, aggregated, and verified across different sources.  
Combines multiple price feeds (e.g., Chainlink, Pyth) to ensure accurate and decentralized price discovery.

- `AggregatorV3TownsqPriceSource.sol` — Integrates Chainlink-compatible price feeds.  
- `BaseTownsqPriceSource.sol` — Abstract base contract for all oracle adapters.  
- `ChainedPriceSource.sol` — Enables chaining multiple price sources for redundancy and fallback.  
- `PythTownsqPriceSource.sol` — Integrates Pyth Network price feeds.  
- `TownsqPriceOracle.sol` — Aggregates prices from multiple sources into a unified oracle interface for the protocol.  
- `TestnetSequencerFeed.sol` — Provides testnet mock price feeds for development and testing environments.

---

### **relayer**
Implements the relayer logic for cross-chain message handling between Hub and Spokes.  
Ensures that deposits, borrows, repayments, and liquidations are reflected accurately across all supported chains.

---

### **create2Factory**
Contains logic for deterministic contract deployments using the `CREATE2` opcode.  
This ensures predictable contract addresses across different networks and simplifies off-chain integration.

---

### **libraries**
Contains reusable utility libraries used throughout the system, such as math helpers, data structures, and address utilities.

---

### **wormhole**
Provides the **Wormhole bridging and messaging infrastructure** that powers cross-chain communication between Hub and Spokes.

- `WormholeTunnel.sol` — Core contract for sending and receiving Wormhole messages between chains.  
- `TokenBridgeUtilities.sol` — Helper utilities for bridging tokens using the Wormhole Token Bridge.  
- `TokenReceiverWithCCTP.sol` — Handles token receipts via Circle’s Cross-Chain Transfer Protocol (CCTP).  
- `TunnelMessageBuilder.sol` — Constructs and decodes structured messages for Hub-Spoke communication.  

---

### **shared**

- `HubSpokeEvents.sol` & `HubSpokeStructs.sol` — Contain shared events and data structures used across Hub and Spoke contracts.  
- `LegacyHubEvents.sol` — Maintains event compatibility with earlier protocol versions. 
- Serves as the **central event registry** for monitoring cross-chain activities.
- `Liquidator.sol` - Manages authorized liquidators and executes profitable liquidation calls through the Hub.
- `LiquidatorFlashLoan.sol` - Extends liquidation with flash loan and swap capabilities to automate cross-chain liquidations profitably.
