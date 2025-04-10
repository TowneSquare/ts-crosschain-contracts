// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWETH} from "@wormhole/interfaces/IWETH.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWormholeTunnel} from "../../interfaces/IWormholeTunnel.sol";
import {IAssetRegistry} from "../../interfaces/IAssetRegistry.sol";
import {ISpoke} from "../../interfaces/ISpoke.sol";
import {TunnelMessageBuilder} from "../wormhole/TunnelMessageBuilder.sol";
import "@wormhole/Utils.sol";

import {HubState} from "./HubState.sol";
import {InterestLogic} from "../../libraries/logic/InterestLogic.sol";
import {MigrationLogic} from "../../libraries/logic/MigrationLogic.sol";
import {ValidationLogic} from "../../libraries/logic/ValidationLogic.sol";
import {CommonAccountingLogic} from "../../libraries/logic/accounting/CommonAccountingLogic.sol";
import {HubAccountingLogic} from "../../libraries/logic/accounting/HubAccountingLogic.sol";
import {HubOptimisticFinalityLogic} from "../../libraries/logic/optimisticFinality/HubOptimisticFinalityLogic.sol";
import {HubSpokeStructs} from "../HubSpokeStructs.sol";
import {LegacyHubEvents} from "../LegacyHubEvents.sol";
import {HubStorage} from "./HubStorage.sol";
import {ILiquidationCalculator} from "../../interfaces/ILiquidationCalculator.sol";

// This contract is to offset the storage of TokenSender and CCTPSender that have been removed from the inheritance
contract StorageGap {
    // contract Base
        // IWormholeRelayer public wormholeRelayer;
        // IWormhole public wormhole;

        // mapping(bytes32 => bool) public seenDeliveryVaaHashes;

        // address registrationOwner;
        // mapping(uint16 => bytes32) registeredSenders;

        // bool internal _wormholeRelayerInitialized;
    // contract TokenBase extends Base
        // ITokenBridge public tokenBridge;
    // contract CCTPBase is TokenBase
        // ITokenMessenger public circleTokenMessenger;
        // IMessageTransmitter public circleMessageTransmitter;
        // address public USDC;

    // the gap array slot itself is one slot (which holds the number of elements in the array)
    // plus it holds 9 slots inside (9 elements in the array)
    // for a total of 10 slots to offset the previous inheritance storage
    // ref: https://docs.soliditylang.org/en/latest/internals/layout_in_storage.html#mappings-and-dynamic-arrays
    uint256[9] private __gap;
}

/**
 * @title Hub
 * @notice The Hub contract maintains state and liquidity for the protocol. It receives cross-chain payloads and tokens
 * using Wormhole, with user interactions happening on Spokes deployed on different chains. Spokes must be registered
 * on the Hub before we can receive messages. Assets must also be registered.
 *
 * TODO: remove LegacyHubEvents post-migration when the grafted subgraph is deployed
 */
contract Hub is
    Initializable,
    StorageGap,
    PausableUpgradeable,
    LegacyHubEvents,
    HubState
{
    using SafeERC20 for IERC20;
    using ValidationLogic for HubSpokeStructs.HubState;
    using HubAccountingLogic for HubSpokeStructs.HubState;
    using InterestLogic for HubSpokeStructs.HubState;
    using HubOptimisticFinalityLogic for HubSpokeStructs.HubState;

    error CreditAlreadyFinalized();
    error InstantActionAlreadyProcessed();
    error InsufficientMsgValue();
    error InsufficientSpokeBalance();
    error InvalidAction();
    error InvalidCredit();
    error InvalidForwardedAmount();
    error InvalidPayloadOrVaa();
    error MigrationRequired();
    error OnlyWormholeTunnel();
    error RenounceOwnershipDisabled();
    error TransferFailed();
    error UnauthorizedSender();
    error UnexpectedTokenReceived();
    error UnregisteredAsset();
    error UnusedParameterMustBeZero();
    error VaultUndercollateralized();
    error ZeroAddress();

    modifier onlyWormholeTunnel() {
        if (msg.sender != address(getWormholeTunnel())) {
            revert OnlyWormholeTunnel();
        }
        _;
    }

    modifier onlySpokeSender(IWormholeTunnel.MessageSource memory source) {
        if (source.sender != HubStorage.getSpokeState(source.chainId).spoke) {
            revert UnauthorizedSender();
        }
        _;
    }

    /**
     * @notice Hub constructor; prevent initialize() from being invoked on the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Hub initializer - Initializes a new hub with given parameters
     *
     * @param args struct with constructor arguments
     */
    function initialize(HubSpokeStructs.ConstructorArgs memory args) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        PausableUpgradeable.__Pausable_init();

        if (args.interestAccrualIndexPrecision < 1e18) {
            revert InvalidPrecision();
        }

        HubSpokeStructs.FeesLimitsAndPrecisionsState storage flpState = HubStorage.getFeesLimitsAndPrecisionsState();

        flpState.interestAccrualIndexPrecision = args.interestAccrualIndexPrecision;
        flpState.defaultGasLimit = 300_000;
        flpState.refundGasLimit = 60_000;
        setLiquidationFee(args.liquidationFee, args.liquidationFeePrecision);
        setWormholeTunnel(address(args.wormholeTunnel));
    }

    function getVaultAmounts(address vaultOwner, bytes32 assetId) public view returns (HubSpokeStructs.DenormalizedVaultAmount memory) {
        // from InterestLogic
        return InterestLogic.getVaultAmounts(vaultOwner, assetId);
    }

    function getGlobalAmounts(bytes32 assetId) public view returns (HubSpokeStructs.DenormalizedVaultAmount memory) {
        // from InterestLogic
        return InterestLogic.getGlobalAmounts(assetId);
    }

    /**
     * @notice Registers a spoke contract. Only wormhole messages from registered spoke contracts are allowed.
     *
     * @param chainId - The chain id which the spoke is deployed on
     * @param spokeAddressWhFormat - The address of the spoke contract on its chain
     * @param spokeWrappedNativeAssetAddress - the b32 home address of the wrapped Spoke chain native asset
     */
    function registerSpoke(uint16 chainId, bytes32 spokeAddressWhFormat, bytes32 spokeWrappedNativeAssetAddress) external onlyOwner {
        HubSpokeStructs.SpokeState storage state = HubStorage.getSpokeState(chainId);
        state.spoke = spokeAddressWhFormat;
        state.wrappedNativeAsset = spokeWrappedNativeAssetAddress;

        emit SpokeRegistered(chainId, spokeAddressWhFormat);
    }

    function getCurrentAccrualIndices(bytes32 assetId) public view returns (HubSpokeStructs.AccrualIndices memory) {
        return InterestLogic.getCurrentAccrualIndices(assetId);
    }

    /**
     * @notice Liquidates a vault. The sender of this transaction pays, for each i, assetRepayAmount[i] of the asset
     * assetRepayAddresses[i] and receives, for each i, assetReceiptAmount[i] of the asset at assetReceiptAddresses[i]
     * A check is made to see if this liquidation attempt should be allowed
     *
     * @param input: The LiquidationInput struct containing the liquidation details, input amounts should be denormalized (real amounts)
     */
    function liquidation(ILiquidationCalculator.LiquidationInput memory input) public whenNotPaused {
        // TODO: remove once all users are migrated
        MigrationLogic.migrateUser(_deprecated_state, input.vault);

        // check if inputs are valid
        ValidationLogic.checkLiquidationInputsValid(input);

        // update all accrual indices
        for (uint256 i = 0; i < input.assets.length;) {
            HubAccountingLogic.updateAccrualIndices(input.assets[i].assetId);
            unchecked {
                i++;
            }
        }

        // check if intended liquidation is valid
        ValidationLogic.checkAllowedToLiquidate(input);

        (uint256 liquidationFee, uint256 precision) = getLiquidationFeeAndPrecision();

        IAssetRegistry assetRegistry = HubStorage.getAuxilaryContracts().assetRegistry;
        uint16 chainId = HubStorage.getAuxilaryContracts().wormholeTunnel.chainId();

        // this flag will flip to true if the liquidator performs any action that could put their own
        // account into an undercollateralized state (such as repay from own vault instead of transfer)
        bool needToCheckLiquidatorHf = false;

        for (uint256 i = 0; i < input.assets.length;) {
            ILiquidationCalculator.DenormalizedLiquidationAsset memory asset = input.assets[i];
            IERC20 assetToken = IERC20(fromWormholeFormat(assetRegistry.getAssetAddress(asset.assetId, chainId)));

            // update vault amounts
            if (asset.repaidAmount > 0) {
                if (asset.repaymentMethod == ILiquidationCalculator.RepaymentMethod.FROM_DEPOSIT) {
                    needToCheckLiquidatorHf = true;
                    HubAccountingLogic.updateVaultAmounts(HubSpokeStructs.Action.Withdraw, msg.sender, asset.assetId, asset.repaidAmount);
                } else if (asset.repaymentMethod == ILiquidationCalculator.RepaymentMethod.DEBT_TAKEOVER) {
                    needToCheckLiquidatorHf = true;
                    HubAccountingLogic.updateVaultAmounts(HubSpokeStructs.Action.Borrow, msg.sender, asset.assetId, asset.repaidAmount);
                } else {
                    // send repay tokens from liquidator to contract
                    assetToken.safeTransferFrom(msg.sender, address(this), asset.repaidAmount);
                }
                HubAccountingLogic.updateVaultAmounts(HubSpokeStructs.Action.Repay, input.vault, asset.assetId, asset.repaidAmount);
            }

            if (asset.receivedAmount > 0) {
                HubAccountingLogic.updateVaultAmounts(HubSpokeStructs.Action.Withdraw, input.vault, asset.assetId, asset.receivedAmount);
                // reward liquidator
                uint256 feePortion = (asset.receivedAmount * liquidationFee) / precision;
                uint256 amountToTransfer = asset.receivedAmount - feePortion;
                if (asset.paymentMethod == ILiquidationCalculator.PaymentMethod.DEPOSIT_TAKEOVER) {
                    HubAccountingLogic.updateVaultAmounts(HubSpokeStructs.Action.Deposit, msg.sender, asset.assetId, amountToTransfer);
                } else {
                    assetToken.safeTransfer(msg.sender, amountToTransfer);
                }
            }

            unchecked {
                i++;
            }
        }

        if (needToCheckLiquidatorHf) {
            // the liquidator performed an action that could put their account underwater
            // need to check if the liquidators account is still collateralized
            HubSpokeStructs.NotionalVaultAmount memory liquidatorNotionals = getPriceUtilities().getVaultEffectiveNotionals(msg.sender, true);
            if (liquidatorNotionals.deposited < liquidatorNotionals.borrowed) {
                revert VaultUndercollateralized();
            }
        }

        emit Liquidation(msg.sender, input.vault, input.assets);
    }

    function sendSpokeTopUp(uint16 spokeChainId, IERC20 token, uint256 amount, uint256 confirmationCost) public payable onlyOwner whenNotPaused {
        HubOptimisticFinalityLogic.handleSendSpokeTopUp(spokeChainId, token, amount, confirmationCost);
    }

    /**
     * @notice Returns the calculated return delivery cost on the given `spokeChainId`
     * @param spokeChainId: The spoke's chainId to forward tokens to
     * @return The calculated return delivery cost
     */
    function getCostForReturnDelivery(uint16 spokeChainId) public view returns (uint256) {
        IWormholeTunnel wormholeTunnel = HubStorage.getAuxilaryContracts().wormholeTunnel;
        uint256 defaultGasLimit = HubStorage.getFeesLimitsAndPrecisionsState().defaultGasLimit;
        return wormholeTunnel.getMessageCost(spokeChainId, defaultGasLimit, 0, true);
    }

    function getInstantActionCosts(uint16 spokeChainId, HubSpokeStructs.Action _action) public view returns (uint256[] memory) {
        return HubOptimisticFinalityLogic.getInstantActionCosts(spokeChainId, _action);
    }

    function userActionMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySpokeSender(source) whenNotPaused {
        HubSpokeStructs.UserActionPayload memory uap = abi.decode(payload, (HubSpokeStructs.UserActionPayload));

        if (_isTokenSend(uap.action)) {
            // only accepting deposits and repays through full finality action
            revert InvalidAction();
        }

        bytes32 assetId = HubStorage.getAuxilaryContracts().assetRegistry.getAssetId(source.chainId, uap.token);
        HubAccountingLogic.requireRegisteredAsset(assetId);

        bytes32 userId = HubAccountingLogic.requireUserId(source.chainId, uap.user);

        // TODO: remove this line when all users migrated
        MigrationLogic.migrateUser(_deprecated_state, fromWormholeFormat(userId));

        HubAccountingLogic.accountForUserAction(
            userId,
            uap.action,
            assetId,
            uap.amount
        );

        // since this message came with full finality, increase the Spoke finalized deposit balance
        HubStorage.getSpokeState(source.chainId).balances[uap.token].finalized += uap.amount;

        // refund any overpaid return message ETH to the user
        _sendRefund(source);
    }

    function instantActionMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySpokeSender(source) whenNotPaused {
        HubOptimisticFinalityLogic.requireNoTokenSent(token, amount);

        HubSpokeStructs.UserActionPayload memory iap = abi.decode(payload, (HubSpokeStructs.UserActionPayload));

        HubSpokeStructs.SpokeState storage spokeState = HubStorage.getSpokeState(source.chainId);
        if (spokeState.maxNonces[iap.user] >= iap.nonce) {
            revert InstantActionAlreadyProcessed();
        }
        spokeState.maxNonces[iap.user] = iap.nonce;

        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();
        bytes32 assetId = auxContracts.assetRegistry.getAssetId(source.chainId, iap.token);
        HubAccountingLogic.requireRegisteredAsset(assetId);

        _requireAssetToBeWethForNativeSendActions(iap.action, source.chainId, assetId);

        bytes32 userId = HubAccountingLogic.requireUserId(source.chainId, iap.user);

        // TODO: remove this line when all users migrated
        MigrationLogic.migrateUser(_deprecated_state, fromWormholeFormat(userId));

        HubAccountingLogic.accountForUserAction(
            userId,
            iap.action,
            assetId,
            iap.amount
        );

        HubOptimisticFinalityLogic.sendInstantActionResponse(iap, source);
    }

    function confirmTopUpMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySpokeSender(source) {
        HubOptimisticFinalityLogic.handleConfirmTopUpMessage(source, token, amount, payload);
    }

    function confirmFixLostCreditMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySpokeSender(source) {
        HubOptimisticFinalityLogic.handleConfirmFixLostCreditMessage(source, token, amount, payload);
    }

    function finalizeCreditMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256 amount,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySpokeSender(source) {
        require(amount == 0, "token forwarding no longer supported");
        HubOptimisticFinalityLogic.handleFinalizeCreditMessage(source, payload);
    }

    function pairingRequestMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySpokeSender(source) {
        HubSpokeStructs.RequestPairingPayload memory rpp = abi.decode(payload, (HubSpokeStructs.RequestPairingPayload));
        HubAccountingLogic.handlePairingRequest(source.chainId, rpp.newAccount, rpp.userId);
    }

    // ============ Same Chain User Functions ============
    /**
     * @notice allows users to perform actions on the vault from the same chain as the vault (ERC20 only)
     * @param action - the action (either Deposit, Borrow, Withdraw, or Repay)
     * @param assetId - the ID of the asset
     * @param amount - the amount of the asset
     */
    function userActions(HubSpokeStructs.Action action, bytes32 assetId, uint256 amount) external payable whenNotPaused {
        if (!_isNativeTokenAction(action) && assetId == bytes32(0)) {
            revert UnusedParameterMustBeZero();
        }

        // TODO: remove this line when all users migrated
        MigrationLogic.migrateUser(_deprecated_state, msg.sender);

        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();
        IWETH weth = auxContracts.assetRegistry.WETH();
        uint16 hubChainId = auxContracts.wormholeTunnel.chainId();

        (action,, amount) = CommonAccountingLogic.handleInboundTokensAndAdjustAction(
            action,
            assetId == bytes32(0) ? address(0) : fromWormholeFormat(auxContracts.assetRegistry.getAssetAddress(assetId, hubChainId)), // asset address on this chain or zero for native
            amount,
            weth
        );

        if (assetId == bytes32(0)) {
            // assetId zero needs to be remapped to WETH
            // earlier check makes sure it's a native action
            assetId = auxContracts.assetRegistry.getAssetId(hubChainId, toWormholeFormat(address(weth)));
        }

        bytes32 msgSenderWhFormat = toWormholeFormat(msg.sender);
        // since this is a local (same-chain) action, msg.sender is both the sender of this action and the refundRecipient
        IWormholeTunnel.MessageSource memory source = IWormholeTunnel.MessageSource(auxContracts.wormholeTunnel.chainId(), msgSenderWhFormat, msgSenderWhFormat);
        HubAccountingLogic.accountForUserAction(
            HubAccountingLogic.requireUserId(hubChainId, msgSenderWhFormat),
            action,
            assetId,
            amount
        );

        if (_isTokenSend(action)) {
            _sendTokens(
                msg.sender,
                assetId,
                amount,
                _isNativeTokenSend(action)
            );
        } else {
            // if any msg.value has been sent for any reason (overpaid, costForReturnDelivery, WhTunnel forwarding a gas refund, etc)
            // then send the remaining value back to the sender
            _sendRefund(source);
        }
    }

    function _sendRefund(IWormholeTunnel.MessageSource memory source) internal {
        IWormholeTunnel wormholeTunnel = HubStorage.getAuxilaryContracts().wormholeTunnel;
        if (source.chainId != wormholeTunnel.chainId()) {
            // refunds only make sense in a cross-chain context
            uint256 cost = wormholeTunnel.getMessageCost(source.chainId, wormholeTunnel.GAS_USAGE_WITHOUT_TOKEN(), 0, false);
            if (msg.value > cost) {
                IWormholeTunnel.TunnelMessage memory message = TunnelMessageBuilder.createMessage(
                    toWormholeFormat(address(this)),
                    source.refundRecipient,
                    source.chainId
                );
                wormholeTunnel.sendEvmMessage{value: msg.value}(message, HubStorage.getFeesLimitsAndPrecisionsState().refundGasLimit);
            }
        }
    }

    function _sendTokens(
        address recipient,
        bytes32 assetId,
        uint256 amount,
        bool unwrapWeth
    ) internal {
        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();
        // same chain transfer
        IERC20 thisChainToken = IERC20(fromWormholeFormat(auxContracts.assetRegistry.getAssetAddress(assetId, auxContracts.wormholeTunnel.chainId())));
        IWETH weth = auxContracts.assetRegistry.WETH();
        if (address(thisChainToken) == address(weth) && unwrapWeth) {
            weth.withdraw(amount);
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            thisChainToken.safeTransfer(recipient, amount);
        }
    }

    function updateAccrualIndices(bytes32 assetId) public whenNotPaused {
        HubAccountingLogic.updateAccrualIndices(assetId);
    }

    // last resort setter in case some unpredicted reverts happen and Spoke balances need to be corrected
    function setSpokeBalances(uint16 chainId, bytes32 homeAddress, uint256 finalized, uint256 unfinalized) external onlyOwner {
        HubSpokeStructs.HubSpokeBalances memory balances;
        balances.finalized = finalized;
        balances.unfinalized = unfinalized;
        HubOptimisticFinalityLogic.setSpokeBalances(chainId, homeAddress, balances);
    }

    function confirmPairingRequest(uint16 _chainId, bytes32 _account) external {
        if (getWormholeTunnel().isEvm(_chainId)) {
            MigrationLogic.migrateUser(_deprecated_state, fromWormholeFormat(_account));
        }
        MigrationLogic.migrateUser(_deprecated_state, msg.sender);

        bytes32 userId = toWormholeFormat(msg.sender); // userId is just the WH formatted address on Hub chain
        HubAccountingLogic.confirmPairingRequest(_chainId, _account, userId);
    }

    // ============ Internal Functions ============

    function _isTokenSend(HubSpokeStructs.Action action) internal pure returns (bool) {
        return action == HubSpokeStructs.Action.Borrow || action == HubSpokeStructs.Action.Withdraw || _isNativeTokenSend(action);
    }

    function _isNativeTokenSend(HubSpokeStructs.Action action) internal pure returns (bool) {
        return action == HubSpokeStructs.Action.BorrowNative || action == HubSpokeStructs.Action.WithdrawNative;
    }

    function _isNativeTokenReceive(HubSpokeStructs.Action action) internal pure returns (bool) {
        return action == HubSpokeStructs.Action.DepositNative || action == HubSpokeStructs.Action.RepayNative;
    }

    function _isNativeTokenAction(HubSpokeStructs.Action action) internal pure returns (bool) {
        return _isNativeTokenSend(action) || _isNativeTokenReceive(action);
    }

    function _spokeChainWethAssetId(uint16 chainId) internal view returns (bytes32) {
        IAssetRegistry assetRegistry = HubStorage.getAuxilaryContracts().assetRegistry;
        return assetRegistry.getAssetId(chainId, HubStorage.getSpokeState(chainId).wrappedNativeAsset);
    }

    function _requireAssetToBeWethForNativeSendActions(
        HubSpokeStructs.Action action,
        uint16 chainId,
        bytes32 assetId
    ) internal view {
        if (_isNativeTokenSend(action) && assetId != _spokeChainWethAssetId(chainId)) {
            // native withdraw or borrow, but invalid token provided
            revert InvalidAction();
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Withdraws reserves from the contract. If the amount is greater than the reserve balance, then
     * the entire reserve balance is withdrawn.
     * @param assetId: The ID of the asset. Pass bytes32(0) for native asset.
     * @param destinationAddress: The address to send the reserves to
     * @param destinationChain: The chain to withdraw to
     * @param amount: The amount of the wrapped asset to withdraw
     */
    function withdrawReserves(bytes32 assetId, uint16 destinationChain, bytes32 destinationAddress, uint256 amount) external payable onlyOwner {
        HubAccountingLogic.withdrawReserves(assetId, destinationChain, destinationAddress, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /**
     * @notice Get the protocol's global reserve amount in for given assetId
     *
     * @param assetId - the ID of the asset
     * @return uint256 The amount of the assetId in the protocol's reserve
     */
    function getReserveAmount(bytes32 assetId) public view returns (uint256) {
        return HubAccountingLogic.getReserveAmount(assetId);
    }

    function getSpokeAddress(uint256 chainId) public view returns (bytes32) {
        return HubStorage.getSpokeState(uint16(chainId)).spoke;
    }

    function getUserId(uint16 chainId, bytes32 userAddress) public view returns (bytes32) {
        return HubAccountingLogic.getUserId(chainId, userAddress);
    }

    function getUserAddress(uint16 chainId, bytes32 userId) public view returns (bytes32) {
        return HubAccountingLogic.getUserAddress(userId, chainId);
    }

    /**
     * @notice Pauses the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function migrateGlobalState() external onlyOwner {
        MigrationLogic.migrateGlobalState(_deprecated_state);
    }

    function migrate() external {
        MigrationLogic.migrateUser(_deprecated_state, msg.sender);
    }

    function migrateUsers(address[] calldata _users) external onlyOwner {
        for (uint256 i = 0; i < _users.length; i++) {
            MigrationLogic.migrateUser(_deprecated_state, _users[i]);
        }
    }

    /**
     * @notice fallback function to receive unwrapped native asset
     */
    fallback() external payable {}

    receive() external payable {}
}
