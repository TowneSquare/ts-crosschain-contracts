// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ILiquidationCalculator} from "../interfaces/ILiquidationCalculator.sol";
import {IHubPriceUtilities} from "../interfaces/IHubPriceUtilities.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {ILegacyAssetRegistry} from "../interfaces/ILegacyAssetRegistry.sol";
import {IWormholeTunnel} from "../interfaces/IWormholeTunnel.sol";
import {IMoneyMarketRewardsDistributor} from "../interfaces/rewards/IMoneyMarketRewardsDistributor.sol";

/**
 * @title HubSpokeStructs
 * @notice A set of structs and enums used in the Hub and Spoke contracts
 */
library HubSpokeStructs {
    /**
     * @param wormhole: Address of the Wormhole contract
     * @param tokenBridge: Address of the TokenBridge contract
     * @param wormholeRelayer: Address of the WormholeRelayer contract
     * @param consistencyLevel: Desired level of finality the Wormhole guardians will reach before signing the messages
     * NOTE: consistencyLevel = 200 will result in an instant message, while all other values will wait for finality
     * Recommended finality levels can be found here: https://book.wormhole.com/reference/contracts.html
     * @param pythAddress: Address of the Pyth oracle on the Hub chain
     * @param priceStandardDeviations: priceStandardDeviations = (psd * priceStandardDeviationsPrecision), where psd is
     * the number of standard deviations that we use for our price intervals in calculations relating to allowing
     * withdraws, borrows, or liquidations
     * @param priceStandardDeviationsPrecision: A precision number that allows us to represent our desired noninteger
     * price standard deviation as an integer (psd = priceStandardDeviations/priceStandardDeviationsPrecision)
     * @param maxLiquidationPortionPrecision: A precision number that allows us to represent our desired noninteger
     * max liquidation portion mlp as an integer (mlp = maxLiquidationPortion/maxLiquidationPortionPrecision)
     * @param interestAccrualIndexPrecision: A precision number that allows us to represent our noninteger interest
     * accrual indices as integers; we store each index as its true value multiplied by interestAccrualIndexPrecision
     * @param collateralizationRatioPrecision: A precision number that allows us to represent our noninteger
     * collateralization ratios as integers; we store each ratio as its true value multiplied by
     * collateralizationRatioPrecision
     * @param liquidationFee: The fee taken by the protocol on liquidation
     * @param _circleMessageTransmitter: Cicle Message Transmitter contract (cctp)
     * @param _circleTokenMessenger: Cicle Token Messenger contract (cctp)
     * @param _USDC: USDC token contract (cctp)
     */
    struct ConstructorArgs {
        /* Liquidation Information */
        uint256 interestAccrualIndexPrecision;
        uint256 liquidationFee;
        uint256 liquidationFeePrecision;
        /* WormholeTunnel */
        IWormholeTunnel wormholeTunnel;
    }

    struct StoredVaultAmount {
        DenormalizedVaultAmount amounts;
        AccrualIndices accrualIndices;
    }

    struct DenormalizedVaultAmount {
        uint256 deposited;
        uint256 borrowed;
    }

    struct NotionalVaultAmount {
        uint256 deposited;
        uint256 borrowed;
    }

    struct AccrualIndices {
        uint256 deposited;
        uint256 borrowed;
    }

    struct UserActionPayload {
        bytes32 user;
        Action action;
        bytes32 token;
        uint256 amount;
        uint256 nonce;
    }

    struct ConfirmCreditPayload {
        Credit credit;
    }

    struct ReleaseFundsPayload {
        bytes32 user;
        bytes32 token;
        uint256 amount;
        uint256 nonce;
        bool unwrapWeth;
    }

    struct ConfirmTopUpPayload {
        bytes32 token;
        uint256 amount;
    }

    struct ConfirmFixLostCreditPayload {
        bytes32 token;
        uint256 amount;
    }

    struct FinalizeCreditPayload {
        Credit credit;
    }

    struct RequestPairingPayload {
        bytes32 newAccount;
        bytes32 userId;
    }

    enum Action {      // mapping to use in Laika so that I don't have to count each time
        Deposit,       // 0
        Borrow,        // 1
        Withdraw,      // 2
        Repay,         // 3
        DepositNative, // 4
        RepayNative,   // 5
        WithdrawNative,// 6
        BorrowNative   // 7
    }

    enum ActionDirection {
        Inbound, // receiving tokens from user: Deposit (+native), Repay (+native)
        Outbound // sending tokens to user: Withdraw (+native), Borrow (+native)
    }

    enum CreditStatus {
        PENDING,     // before confirmation arrives
        CONFIRMED,   // after Hub confirms it
        REFUNDABLE,  // if it gets finalized, but hasn't been confirmed earlier
        FINALIZED,   // after it gets finalized. terminal status.
        REFUNDED,    // after a refund is processed. terminal status.
        LOST         // after a credit conflict is found. this means that the deposit/repay was accounted for, but the Credit got reorg'd and there now is a deficit. terminal status.
    }

    struct Credit {
        bytes32 user;
        bytes32 token;
        uint256 creditedAmount;
        uint256 _deprecated_forwardedAmount;
        uint256 nonce;
        uint256 createdAt;
        uint256 updatedAt;
        CreditStatus status;
    }

    struct SpokeBalances {
        uint256 creditGiven; // amount of tokens sent by the user to the Spoke, but not yet finalized
        uint256 creditLost; // amount of credit that got reorg'd and then stolen
        uint256 unlocksPending; // amount of non-finalized Spoke-side deposits
        uint256 creditLimit; // the limit of tokens that can be sent in flight
        uint256 custodyLimit; // the limit of tokens that can be held in custody
        uint256 transactionLimit; // the limit of tokens that can be transferred in a single TX
        uint256 deposits; // the amount of finalized tokens that are user deposits (as opposed to credit or protocol reserves. deposits = balance - reserve - credit)
        uint256 lastUpdated; // the last block timestamp the balances were updated
    }

    struct SpokeFundRelease {
        uint256 nonce;     // the user nonce of the release
        bytes32 user;      // the user receiving the released tokens
        bytes32 token;     // the token being released
        uint256 amount;    // the amount being released
        uint256 releasedAt;// the timestamp of the release
    }

    struct HubSpokeBalances {
        uint256 finalized;
        uint256 unfinalized;
    }

    struct SpokeState {
        bytes32 spoke; // the address of the Spoke
        bytes32 wrappedNativeAsset; // the address of the wrapped native asset on the Spoke chain
        // assetId => SpokeBalances
        mapping(bytes32 => HubSpokeBalances) balances;
        // user as bytes32 => nonce => Credit struct
        mapping(bytes32 => mapping(uint256 => Credit)) credits;
        // user as bytes32 => nonce
        mapping(bytes32 => uint256) maxNonces;

        uint256[50] __gap; // gap for additional params
    }

    struct HubState {
        // number of confirmations for wormhole messages
        uint8 _deprecated_consistencyLevel;
        // vault for lending. user => token => amounts
        mapping(address => mapping(address => HubSpokeStructs.StoredVaultAmount)) _deprecated_vault;
        // total asset amounts (tokenAddress => (uint256, uint256))
        mapping(address => HubSpokeStructs.StoredVaultAmount) _deprecated_totalAssets;
        // interest accrual indices
        mapping(address => HubSpokeStructs.AccrualIndices) _deprecated_indices;
        // last timestamp for update
        mapping(address => uint256) _deprecated_lastActivityBlockTimestamps;
        // interest accrual rate precision level
        uint256 _deprecated_interestAccrualIndexPrecision;
        // calculator for liquidation amounts
        ILiquidationCalculator _deprecated_liquidationCalculator;
        // price utilities for getting prices
        IHubPriceUtilities _deprecated_priceUtilities;
        // asset registry for getting asset info
        ILegacyAssetRegistry _deprecated_assetRegistry;
        // protocol fee taken on liquidation
        uint256 _deprecated_liquidationFee;
        // for wormhole relay quotes
        uint256 _deprecated_defaultGasLimit;
        // for refunding of returnCost amount
        uint256 _deprecated_refundGasLimit;
        // toggle for using CCTP for asset => USDC
        bool _deprecated_isUsingCCTP;
        // the precision of the liquidation fee
        uint256 _deprecated_liquidationFeePrecision;
        // chainId => SpokeParams
        mapping(uint16 => SpokeState) _deprecated_spokeStates;

        IWormholeTunnel _deprecated_wormholeTunnel;

        // this mirrors the spokeBalances but as wrapped addresses
        // this is done so that reserves can be computed without knowing the Spoke address of the token
        // this will be deprecated once we move to full Spoke custody of funds
        mapping(address => HubSpokeBalances) _deprecated_wrappedTokenSpokeBalances;
        IMoneyMarketRewardsDistributor _deprecated_rewardDistributor;
    }

    struct AssetState {
        StoredVaultAmount totals;
        AccrualIndices indices;
        uint256 lastActivityBlockTimestamp;
        mapping(address => HubSpokeStructs.StoredVaultAmount) userVaults;
    }

    struct UserIdState {
        // address remapping for non-EVM chains and multisig support
        // the core idea is that the accounts are indexed by Hub chain account address (userId)
        // additional addresses can be paired with the userId (one per spoke chain)
        // hub account address as b32 (userId) => chainId => spoke address
        mapping(bytes32 => mapping(uint16 => bytes32)) spokeChainAddresses;
        // chainId => spoke address => hub account address as b32 (userId)
        // the addressing is incompatible with spokeChainAddresses to prevent errors
        mapping(uint16 => mapping(bytes32 => bytes32)) userIds;
        // chainId => requesting address => userId
        mapping(uint16 => mapping(bytes32 => bytes32)) pairingRequests;
    }

    struct FeesLimitsAndPrecisionsState {
        // interest accrual rate precision level
        uint256 interestAccrualIndexPrecision;
        // protocol fee taken on liquidation
        uint256 liquidationFee;
        // for wormhole relay quotes
        uint256 defaultGasLimit;
        // for refunding of returnCost amount
        uint256 refundGasLimit;
        // the precision of the liquidation fee
        uint256 liquidationFeePrecision;
    }

    struct AuxilaryContracts {
        // calculator for liquidation amounts
        ILiquidationCalculator liquidationCalculator;
        // price utilities for getting prices
        IHubPriceUtilities priceUtilities;
        // asset registry for getting asset info
        IAssetRegistry assetRegistry;
        // the tunnel through which Hub and Spokes communicate
        IWormholeTunnel wormholeTunnel;
        // the reward distribution contract
        IMoneyMarketRewardsDistributor rewardDistributor;
    }

    struct SpokeCommunicationState {
        IWormholeTunnel wormholeTunnel;
        uint16 hubChainId;
        bytes32 hubContractAddress;
        uint256 defaultGasLimitRoundtrip;
        uint256[50] __gap;
    }

    struct SpokeOptimisticFinalityState {
        uint256 inboundTokenInstantMessageFee; // the percentage fee for instant messages accepting tokens. INSTANT_MESSAGE_FEE_PRECISION = 100%
        uint256 outboundTokenInstantMessageFee; // the percentage fee for instant messages sending tokens. INSTANT_MESSAGE_FEE_PRECISION = 100%
        mapping(bytes32 => HubSpokeStructs.SpokeBalances) tokenBalances; // bytes32 (wormhole format) address of the token => SpokeBalances
        mapping(address => mapping(uint256 => HubSpokeStructs.Credit)) storedCredits; // user => nonce => Credit
        mapping(address => mapping(uint256 => HubSpokeStructs.SpokeFundRelease)) fundReleases; // user => nonce => SpokeFundRelease
        mapping(address => uint256) lastInstantActionNonces; // user => nonce
        uint256 avgTransactionsPerTopUp;
        uint256[50] __gap;
    }
}
