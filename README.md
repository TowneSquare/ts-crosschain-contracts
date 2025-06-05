# TownSq LifeLine Contracts

This repository contains the smart contracts powering the TownSq Lifeline Lending Protocol.

## Quick Start

Both Hardhat and Foundry are utilized for development and testing.

**Setup Instructions:**

1. Clone this repository.
2. Execute `npm install` to install dependencies.
3. Run `forge install` to install Foundry packages.

**Building the Project:**

1. (Optional) Clean previous builds with `npm run clean`.
2. Compile the contracts using `npm run build`.

## Contract Organization

The contracts are organized into six main directories:

- `contracts/bridge`: Handles contracts for transmitting data and tokens between hub and spoke chains. Unless otherwise noted, these are deployed on both hub and spoke chains.
- `contracts/hub`: Contains contracts responsible for the protocol’s main logic, deployed exclusively on the hub chain.
- `contracts/hub-rewards`: Implements the on-chain rewards logic, also deployed only on the hub chain.
- `contracts/oracle`: Provides contracts for token price feeds, deployed solely on the hub chain.
- `contracts/spoke`: Includes contracts that serve as user entry points, deployed on spoke chains (the hub chain may also act as a spoke).
- `contracts/spoke-rewards`: Contains contracts for user access to on-chain rewards, deployed on spoke chains (the hub chain may also act as a spoke).

Each directory may include a `test` subfolder with contracts used exclusively for testing purposes. These are not part of the deployed protocol.

## Running Tests

- To execute all tests: `npm run test`
- To run a specific test file: `npm run test ${PATH_TO_FILE}`

## Licensing

If a license file exists within a subdirectory (e.g., `/contracts/oracle`), it governs all files in that directory. Otherwise, refer to the root-level license.