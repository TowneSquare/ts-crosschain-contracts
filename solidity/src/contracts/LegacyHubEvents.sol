// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ILiquidationCalculator {
    struct DenormalizedLiquidationAsset {
        address assetAddress;
        uint256 repaidAmount;
        uint256 receivedAmount;
        bool depositTakeover;
    }

    struct LiquidationInput {
        address vault;
        DenormalizedLiquidationAsset[] assets;
    }
}

/**
 * @title LegacyHubEvents
 * @notice Pre-UL events emitted by the Hub
 */
contract LegacyHubEvents {
    event Liquidation(address indexed liquidator, address indexed vault, ILiquidationCalculator.DenormalizedLiquidationAsset[] liquidationAssets);
    event Deposit(address indexed vault, address indexed asset, uint256 amount, uint256 vaultTotalDeposited);
    event Withdraw(address indexed vault, address indexed asset, uint256 amount, uint256 vaultTotalDeposited);
    event Borrow(address indexed vault, address indexed asset, uint256 amount, uint256 vaultTotalBorrowed);
    event Repay(address indexed vault, address indexed asset, uint256 amount, uint256 vaultTotalBorrowed);
    event ReservesWithdrawn(address indexed asset, uint256 amount, address destination);

    event SpokeRegistered(uint16 chainId, address spoke);

    event AccrualIndexUpdated(address indexed asset, uint256 deposit, uint256 borrow, uint256 timestamp);
}