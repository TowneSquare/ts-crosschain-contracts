// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWETH} from "@wormhole/interfaces/IWETH.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISpoke} from "../../interfaces/ISpoke.sol";
import {IHub} from "../../interfaces/IHub.sol";
import {IWormholeTunnel} from "../../interfaces/IWormholeTunnel.sol";

import {HubSpokeStructs} from "../HubSpokeStructs.sol";
import {HubSpokeEvents} from "../HubSpokeEvents.sol";

import {TunnelMessageBuilder} from "../wormhole/TunnelMessageBuilder.sol";
import {SpokeOptimisticFinalityLogic} from "../../libraries/logic/optimisticFinality/SpokeOptimisticFinalityLogic.sol";
import {CommonAccountingLogic} from "../../libraries/logic/accounting/CommonAccountingLogic.sol";
import {SpokeAccountingLogic} from "../../libraries/logic/accounting/SpokeAccountingLogic.sol";

import "@wormhole/Utils.sol";

/**
 * @title Spoke
 * @notice The Spoke contract is the point of entry for cross-chain actions; users initiate an action by calling any of
 * the `public payable` functions (ex: `#depositCollateral`, `#withdrawCollateral`) with their desired asset and amount,
 * and using Wormhole we send the payload/tokens to the Hub on the target chain; if the action concludes with sending
 * tokens back to the user, we receive the final payload/tokens from the Hub before sending tokens to the user. This
 * contract also implements wormhole's CCTP contracts to send/receive USDC.
 */

contract Spoke is ISpoke, Initializable, OwnableUpgradeable, PausableUpgradeable, HubSpokeEvents {
    using SafeERC20 for IERC20;
    using SpokeOptimisticFinalityLogic for HubSpokeStructs.SpokeOptimisticFinalityState;

    HubSpokeStructs.SpokeCommunicationState commState;
    HubSpokeStructs.SpokeOptimisticFinalityState ofState;
    IWETH public weth;

    modifier onlyWormholeTunnel() {
        if (msg.sender != address(commState.wormholeTunnel)) {
            revert OnlyWormholeTunnel();
        }
        _;
    }

    modifier onlyHubSender(IWormholeTunnel.MessageSource calldata source) {
        if (source.sender != commState.hubContractAddress || source.chainId != commState.hubChainId) {
            revert OnlyHubSender();
        }
        _;
    }

    /**
     * @notice Spoke initializer - Initializes a new spoke with given parameters
     * @param _hubChainId: Chain ID of the Hub
     * @param _hubContractAddress: Contract address of the Hub contract (on the Hub chain)
     * @param _tunnel: The Wormhole tunnel contract
     */
    function initialize(
        uint16 _hubChainId,
        address _hubContractAddress,
        IWormholeTunnel _tunnel,
        IWETH _weth
    ) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        PausableUpgradeable.__Pausable_init();
        commState.hubChainId = _hubChainId;
        commState.hubContractAddress = toWormholeFormat(_hubContractAddress);
        commState.wormholeTunnel = _tunnel;
        commState.defaultGasLimitRoundtrip = 5_000_000;

        ofState.avgTransactionsPerTopUp = 10;

        weth = _weth;
    }

    /**
     * @notice Allows the contract deployer to set the default gas limit used in wormhole relay quotes
     *
     * @param value: the new value for `defaultGasLimitRoundtrip`
     */
    function setDefaultGasLimitRoundtrip(uint256 value) external onlyOwner {
        commState.defaultGasLimitRoundtrip = value;
    }

    function getCommState() public view returns (HubSpokeStructs.SpokeCommunicationState memory) {
        return commState;
    }

    function setLimits(address _token, uint256 _creditLimit, uint256 _custodyLimit, uint256 _transactionLimit) external onlyOwner {
        ofState.setLimits(_token, _creditLimit, _custodyLimit, _transactionLimit);
    }

    function getSpokeBalances(address _token) external view returns (HubSpokeStructs.SpokeBalances memory) {
        return ofState.tokenBalances[toWormholeFormat(_token)];
    }

    function getCredit(address _user, uint256 _nonce) external view returns (HubSpokeStructs.Credit memory) {
        return ofState.storedCredits[_user][_nonce];
    }

    function getInstantMessageFee(HubSpokeStructs.ActionDirection _direction) external view returns (uint256) {
        return _direction == HubSpokeStructs.ActionDirection.Inbound ? ofState.inboundTokenInstantMessageFee : ofState.outboundTokenInstantMessageFee;
    }

    function getLastUserActionNonce(address _user) external view returns (uint256) {
        return ofState.lastInstantActionNonces[_user];
    }

    // getter for backward compatibility
    function defaultGasLimitRoundtrip() external view returns (uint256) {
        return commState.defaultGasLimitRoundtrip;
    }

    function setInstantMessageFees(uint256 _inboundTokenInstantMessageFee, uint256 _outboundTokenInstantMessageFee) external onlyOwner {
        ofState.setInstantMessageFees(_inboundTokenInstantMessageFee, _outboundTokenInstantMessageFee);
    }

    function setHub(uint16 _hubChainId, address _hubContractAddress) external onlyOwner {
        commState.hubChainId = _hubChainId;
        commState.hubContractAddress = toWormholeFormat(_hubContractAddress);
    }

    function setWormholeTunnel(IWormholeTunnel _tunnel) external onlyOwner {
        commState.wormholeTunnel = _tunnel;
    }

    function _checkAndConvertNativeOutboundAsset(HubSpokeStructs.Action action, IERC20 asset) internal view returns (IERC20) {
        if (action == HubSpokeStructs.Action.BorrowNative || action == HubSpokeStructs.Action.WithdrawNative) {
            if (address(asset) != address(0)) {
                revert UnusedParameterMustBeZero();
            }
            asset = IERC20(address(weth));
        }
        return asset;
    }

    function userActions(HubSpokeStructs.Action action, IERC20 asset, uint256 amount, uint256 costForReturnDelivery) external payable {
        asset = _checkAndConvertNativeOutboundAsset(action, asset);
        if (!_isTokenSend(action)) {
            // withdrawals and borrows are redirected to the OF flow by default
            uint256[] memory returnCosts = new uint256[](1);
            returnCosts[0] = costForReturnDelivery;
            SpokeOptimisticFinalityLogic.handleInstantAction(ofState, commState, weth, action, address(asset), amount, returnCosts);
            return;
        }

        // from this point the action is guaranteed to be a full finality deposit or repay (+native)
        if (costForReturnDelivery > 0) {
            // there is no return delivery, because the funds are custodied by the Spoke
            revert InvalidDeliveryCost();
        }

        uint256 totalCost = getFullFinalityDepositRepayCost();
        if (msg.value < totalCost) {
            revert InsufficientMsgValue();
        }
        uint256 valueToSend = msg.value;
        address assetAddress = address(asset);
        // this remaps the action, asset and amount in case of native transfers
        (action, assetAddress, amount, valueToSend) = CommonAccountingLogic.handleInboundTokensAndAdjustAction(action, assetAddress, amount, weth, totalCost);

        HubSpokeStructs.SpokeBalances storage balances = ofState.tokenBalances[toWormholeFormat(assetAddress)];
        if (balances.deposits + amount > balances.custodyLimit) {
            revert CustodyLimitExceeded();
        }
        balances.deposits += amount;

        if (amount == 0) {
            revert InvalidAmount();
        }

        IWormholeTunnel.TunnelMessage memory message;

        message.source.refundRecipient = toWormholeFormat(msg.sender);
        message.source.sender = toWormholeFormat(address(this));

        message.target.chainId = commState.hubChainId;
        message.target.recipient = commState.hubContractAddress;
        message.target.selector = IHub.userActionMessage.selector;
        message.target.payload = abi.encode(HubSpokeStructs.UserActionPayload({
            user: toWormholeFormat(msg.sender),
            action: action,
            token: toWormholeFormat(address(assetAddress)),
            amount: amount,
            nonce: 0 // nonce is unused in full finality message flow
        }));

        commState.wormholeTunnel.sendEvmMessage{value: valueToSend}(
            message,
            commState.defaultGasLimitRoundtrip
        );
    }

    function instantActions(
        HubSpokeStructs.Action action,
        IERC20 asset,
        uint256 amount,
        uint256[] calldata costForReturnDelivery
    )  external payable {
        asset = _checkAndConvertNativeOutboundAsset(action, asset);
        SpokeOptimisticFinalityLogic.handleInstantAction(ofState, commState, weth, action, address(asset), amount, costForReturnDelivery);
    }

    function requestPairing(bytes32 userId) external payable {
        SpokeAccountingLogic.handlePairingRequest(commState, userId);
    }

    function getPairingCost() public view returns (uint256) {
        return SpokeAccountingLogic.getPairingCost(commState);
    }

    /**
     * @notice Get the quote for the wormhole delivery cost of a full finality deposit/repay message
     *
     * @return cost for delivering a full finality deposit/repay message to the Hub
     *
     */
    function getFullFinalityDepositRepayCost()
        public
        view
        returns (uint256)
    {
        return commState.wormholeTunnel.getMessageCost(
            commState.hubChainId,
            commState.defaultGasLimitRoundtrip,
            0, // since introducing unified liquidity the return cost is always zero
            false // since introducing unified liquidity no tokens are being transferred through TokenBridge
        );
    }

    function getInstantActionDeliveryCosts(HubSpokeStructs.Action, uint256[] calldata returnCosts) public view returns (uint256 total, uint256[] memory costs) {
        return SpokeOptimisticFinalityLogic.getInstantActionDeliveryCosts(commState, returnCosts);
    }

    function getReserveAmount(address asset) public view returns (uint256) {
        return SpokeAccountingLogic.getReserveAmount(ofState, asset);
    }

    // local reserves withdrawal
    function withdrawReserves(address asset, uint256 amount, address recipient) external onlyOwner {
        SpokeAccountingLogic.withdrawReserves(ofState, asset, amount, recipient);
    }

    function _isTokenSend(HubSpokeStructs.Action action) internal pure returns (bool) {
        return action == HubSpokeStructs.Action.Deposit || action == HubSpokeStructs.Action.Repay || action == HubSpokeStructs.Action.DepositNative || action == HubSpokeStructs.Action.RepayNative;
    }

    function releaseFunds(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlyHubSender(source) {
        SpokeOptimisticFinalityLogic.handleReleaseFunds(ofState, weth, payload);
    }

    function topUp(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata
    ) external payable onlyWormholeTunnel onlyHubSender(source) {
        SpokeOptimisticFinalityLogic.handleTopUp(ofState, commState, source, token, amount);
    }

    function confirmCredit(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlyHubSender(source) {
        SpokeOptimisticFinalityLogic.handleConfirmCredit(ofState, payload);
    }

    function finalizeCredit(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlyHubSender(source) {
        SpokeOptimisticFinalityLogic.handleFinalizeCredit(ofState, payload);
    }

    function fixLostCredit(IERC20 token, uint256 amount, bool fromReserves) external payable onlyOwner {
        SpokeOptimisticFinalityLogic.handleFixLostCredit(ofState, commState, token, amount, fromReserves);
    }

    function refundCredit(address _user, uint256 _nonce) external onlyOwner {
        SpokeOptimisticFinalityLogic.handleRefundCredit(ofState, _user, _nonce);
    }

    // last resort setter in case some unpredicted reverts happen and Spoke balances need to be corrected
    function overrideBalances(address token, uint256 creditGiven, uint256 unlocksPending, uint256 deposits, uint256 creditLost) external onlyOwner {
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(token)];
        balance.creditGiven = creditGiven;
        balance.unlocksPending = unlocksPending;
        balance.deposits = deposits;
        balance.creditLost = creditLost;
    }

    function refundFailedDeposit(address _user, address _token, uint256 _amount) external onlyOwner {
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(_token)];
        IERC20 tokenE20 = IERC20(_token);
        if (balance.deposits < _amount || tokenE20.balanceOf(address(this)) < _amount) {
            revert InsufficientFunds();
        }
        balance.deposits -= _amount;
        tokenE20.safeTransfer(_user, _amount);
        emit SpokeRefundSent(_user, _token, _amount);
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

    /**
     * @notice fallback function to receive unwrapped native asset
     */
    fallback() external payable {}

    receive() external payable {}
}
