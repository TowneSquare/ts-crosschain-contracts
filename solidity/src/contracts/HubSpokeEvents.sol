// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../interfaces/ILiquidationCalculator.sol";

/**
 * @title HubSpokeEvents
 * @notice Events emitted by the Hub and Spoke contracts
 */
contract HubSpokeEvents {
    event Liquidation(address indexed liquidator, address indexed vault, ILiquidationCalculator.DenormalizedLiquidationAsset[] liquidationAssets);
    event AccrualIndexUpdated(bytes32 indexed asset, uint256 deposit, uint256 borrow, uint256 timestamp);
    event Deposit(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalDeposited);
    event Withdraw(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalDeposited);
    event Borrow(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalBorrowed);
    event Repay(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalBorrowed);
    event ReservesWithdrawn(bytes32 indexed asset, uint256 amount, uint16 destinationChain, bytes32 destinationAddress);
    event SpokeRegistered(uint16 chainId, bytes32 spoke);

    event GlobalStateMigrated();
    event UserMigrated(address indexed user);

    event SetLiquidationFee(uint256 value, uint256 precision);

    event SpokeCreditCreated(address indexed user, address indexed asset, uint256 amount, uint256 nonce);
    event SpokeCreditLost(address indexed user, address indexed asset, uint256 amount, uint256 nonce);
    event SpokeCreditRefundable(address indexed user, address indexed asset, uint256 amount, uint256 nonce);
    event SpokeCreditConfirmed(uint256 nonce);
    event SpokeCreditFinalized(uint256 nonce);
    event SpokeCreditRefunded(address indexed user, address indexed asset, uint256 amount, uint256 nonce);
    event SpokeLimitsChanged(address indexed asset, uint256 creditLimit, uint256 custodyLimit, uint256 transactionLimit);
    event SpokeFeesChanged(uint256 inboundTokenFee, uint256 outboundTokenFee);
    event SpokeFundsReleased(address indexed user, address indexed asset, uint256 amount, uint256 nonce);
    event SpokeTopUpReceived(address indexed asset, uint256 amount);
    event SpokeRefundSent(address user, address token, uint256 amount);

    event HubCreditCreated(uint16 indexed chainId, bytes32 indexed user, bytes32 indexed asset, uint256 amount, uint256 nonce);
    event HubCreditLost(uint16 indexed chainId, bytes32 indexed user, bytes32 indexed asset, uint256 amount, uint256 nonce);
    event HubCreditRefundable(uint16 indexed chainId, bytes32 indexed user, bytes32 indexed asset, uint256 amount, uint256 nonce);
    event HubCreditFinalized(uint16 indexed chainId, uint256 nonce);

    event PossibleHubMisconfiguration(address assetSentAsWeth, address realWeth);

    event AccountPaired(uint16 indexed chainId, bytes32 indexed account, bytes32 indexed userId);
    event AccountPairingRequestReceived(uint16 indexed chainId, bytes32 indexed account, bytes32 indexed userId);
}
