# TownSq LifeLine Contracts
This repository contains the smart contracts that drive the TownSq Lifeline Lending Protocol.

## Getting Started
Development and testing use both Hardhat and Foundry environments.

## Setup
Clone the repository to your local machine.

Run `npm install` to install dependencies.

Run `forge install` to install Foundry dependencies.

## 🛠 Build Instructions
(Optional) Clear out old build artifacts with `npm run clean`.

Compile all contracts using `npm run build`.

## Contract Structure
The smart contracts are divided into the following key directories:

contracts/bridge: Contracts for cross-chain communication and token bridging. These are typically deployed on both hub and spoke chains.

contracts/hub: Core lending logic lives here. These contracts are only deployed to the hub chain.

contracts/hub-rewards: Responsible for distributing protocol rewards on-chain. Hub-only.

contracts/oracle: Manages token price feeds; deployed solely on the hub.

contracts/spoke: User-facing contracts that act as entry points. Deployed on spoke chains (and optionally the hub).

contracts/spoke-rewards: Interfaces for users to claim on-chain rewards. Deployed on spoke chains, and optionally on the hub.

Each folder may also contain a test subdirectory used only for internal testing — these are not part of the deployed system.

## Running Tests
Run all tests: `npm run test`

Run a specific test file: `npm run test path/to/TestFile.t.sol`

##  License
Each subdirectory may include its own license file. If one exists, it takes precedence for all contents in that folder. Otherwise, refer to the license file at the root of this repository.

