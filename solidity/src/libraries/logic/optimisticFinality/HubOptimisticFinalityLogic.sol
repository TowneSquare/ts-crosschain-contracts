// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWormholeTunnel} from "../../../interfaces/IWormholeTunnel.sol";
import {IAssetRegistry} from "../../../interfaces/IAssetRegistry.sol";
import {ISpoke} from "../../../interfaces/ISpoke.sol";
import {IHub} from "../../../interfaces/IHub.sol";
import {IWETH} from "@wormhole/interfaces/IWETH.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HubSpokeStructs} from "../../../contracts/HubSpokeStructs.sol";
import {HubSpokeEvents} from "../../../contracts/HubSpokeEvents.sol";
import {HubStorage} from "../../../contracts/lendingHub/HubStorage.sol";
import "@wormhole/Utils.sol";

import {TokenBridgeUtilities} from "../../../contracts/wormhole/TokenBridgeUtilities.sol";

import {HubAccountingLogic} from "../accounting/HubAccountingLogic.sol";
import {CommonOptimisticFinalityLogic} from "./CommonOptimisticFinalityLogic.sol";

interface IBridgeToken {
    function nativeContract() external view returns (bytes32);
    function chainId() external view returns (uint16);
}

library HubOptimisticFinalityLogic {
    using SafeERC20 for IERC20;

    // events need to be in both library and contract to be picked up
    // see: https://ethereum.stackexchange.com/questions/11137/watching-events-defined-in-libraries
    event HubCreditCreated(uint16 indexed chainId, bytes32 indexed user, bytes32 indexed asset, uint256 amount, uint256 nonce);
    event HubCreditLost(uint16 indexed chainId, bytes32 indexed user, bytes32 indexed asset, uint256 amount, uint256 nonce);
    event HubCreditFinalized(uint16 indexed chainId, uint256 nonce);
    event HubCreditRefundable(uint16 indexed chainId, bytes32 indexed user, bytes32 indexed asset, uint256 amount, uint256 nonce);
    // end events from HubSpokeEvents

    error CreditAlreadyFinalized();
    error CreditLimitExceeded();
    error FundsAlreadyReleased();
    error InsufficientFunds();
    error InsufficientMsgValue();
    error InsufficientSpokeBalance();
    error InvalidAction();
    error InvalidAmount();
    error InvalidCostForReturnDeliveryLength();
    error InvalidForwardedAmount();
    error InvalidReleaseFundsPayload();
    error TransactionLimitExceeded();
    error UnexpectedTokenReceived();

    function SPOKE_CONFIRM_MESSAGE_GAS_LIMIT() public pure returns (uint256) {
        return 250_000;
    }

    function SPOKE_FINALIZE_MESSAGE_GAS_LIMIT() public pure returns (uint256) {
        return 250_000;
    }

    function SPOKE_RELEASE_FUNDS_GAS_LIMIT() public pure returns (uint256) {
        return 300_000;
    }

    function SPOKE_TOP_UP_GAS_LIMIT() public pure returns (uint256) {
        return 500_000;
    }

    function getInstantActionCosts(
        uint16 spokeChainId,
        HubSpokeStructs.Action _action
    ) public view returns (uint256[] memory) {
        IWormholeTunnel wormholeTunnel = HubStorage.getAuxilaryContracts().wormholeTunnel;
        uint256[] memory costs;
        if (CommonOptimisticFinalityLogic.getActionDirection(_action) == HubSpokeStructs.ActionDirection.Inbound) {
            costs = new uint256[](2);
            // the cost for sending back the credit confirmation message
            costs[0] = wormholeTunnel.getMessageCost(spokeChainId, SPOKE_CONFIRM_MESSAGE_GAS_LIMIT(), 0, false);
            // the cost for sending back the credit finalization message
            costs[1] = wormholeTunnel.getMessageCost(spokeChainId, SPOKE_FINALIZE_MESSAGE_GAS_LIMIT(), 0, false);
        } else {
            costs = new uint256[](1);
            // the cost for sending the release funds message
            costs[0] = wormholeTunnel.getMessageCost(spokeChainId, SPOKE_RELEASE_FUNDS_GAS_LIMIT(), 0, false);
        }
        return costs;
    }

    function requireNoTokenSent(IERC20 asset, uint256 amount) public pure {
        if (asset != IERC20(address(0)) || amount > 0) {
            revert UnexpectedTokenReceived();
        }
    }

    function sendInstantActionResponse(
        HubSpokeStructs.UserActionPayload memory iap,
        IWormholeTunnel.MessageSource memory source
    ) public {
        IWormholeTunnel wormholeTunnel = HubStorage.getAuxilaryContracts().wormholeTunnel;
        HubSpokeStructs.SpokeState storage spokeState = HubStorage.getSpokeState(source.chainId);
        HubSpokeStructs.HubSpokeBalances memory balances = spokeState.balances[iap.token];

        if (CommonOptimisticFinalityLogic.getActionDirection(iap.action) == HubSpokeStructs.ActionDirection.Inbound) {
            spokeState.credits[iap.user][iap.nonce] = HubSpokeStructs.Credit({
                user: iap.user,
                token: iap.token,
                creditedAmount: iap.amount,
                _deprecated_forwardedAmount: 0, // token forwarding has been disabled
                nonce: iap.nonce,
                createdAt: block.timestamp,
                updatedAt: block.timestamp,
                status: HubSpokeStructs.CreditStatus.CONFIRMED
            });
            emit HubCreditCreated(source.chainId, iap.user, iap.token, iap.amount, iap.nonce);

            balances.unfinalized += iap.amount;

            setSpokeBalances(
                source.chainId,
                iap.token,
                balances
            );

            IWormholeTunnel.TunnelMessage memory message;
            message.source = IWormholeTunnel.MessageSource(wormholeTunnel.chainId(), toWormholeFormat(address(this)), source.refundRecipient);
            message.target = IWormholeTunnel.MessageTarget({
                chainId: source.chainId,
                recipient: spokeState.spoke,
                selector: ISpoke.confirmCredit.selector,
                payload: abi.encode(HubSpokeStructs.ConfirmCreditPayload({
                    credit: spokeState.credits[iap.user][iap.nonce]
                }))
            });
            message.finality = IWormholeTunnel.MessageFinality.INSTANT;

            uint256 confirmCreditCost = wormholeTunnel.getMessageCost(source.chainId, SPOKE_CONFIRM_MESSAGE_GAS_LIMIT(), 0, false);
            if (msg.value < confirmCreditCost) {
                revert InsufficientMsgValue();
            }

            wormholeTunnel.sendEvmMessage{value: confirmCreditCost}(message, SPOKE_CONFIRM_MESSAGE_GAS_LIMIT());
        } else {
            if (balances.finalized < iap.amount) {
                revert InsufficientSpokeBalance();
            }

            // reduce the tracked Spoke balance of the token
            // this prevents authorizing release of non-existent funds in the future
            balances.finalized -= iap.amount;
            setSpokeBalances(
                source.chainId,
                iap.token,
                balances
            );

            IWormholeTunnel.TunnelMessage memory message;
            message.source = IWormholeTunnel.MessageSource(wormholeTunnel.chainId(), toWormholeFormat(address(this)), source.refundRecipient);
            message.target = IWormholeTunnel.MessageTarget({
                chainId: source.chainId,
                recipient: spokeState.spoke,
                selector: ISpoke.releaseFunds.selector,
                payload: abi.encode(HubSpokeStructs.ReleaseFundsPayload({
                    user: iap.user,
                    token: iap.token,
                    amount: iap.amount,
                    nonce: iap.nonce,
                    unwrapWeth: iap.action == HubSpokeStructs.Action.WithdrawNative || iap.action == HubSpokeStructs.Action.BorrowNative
                }))
            });
            message.finality = IWormholeTunnel.MessageFinality.INSTANT;
            uint256 releaseFundsCost = wormholeTunnel.getMessageCost(source.chainId, SPOKE_RELEASE_FUNDS_GAS_LIMIT(), 0, false);
            if (msg.value < releaseFundsCost) {
                revert InsufficientMsgValue();
            }

            wormholeTunnel.sendEvmMessage{value: releaseFundsCost}(message, SPOKE_RELEASE_FUNDS_GAS_LIMIT());
        }
    }

    function handleFinalizeCreditMessage(
        IWormholeTunnel.MessageSource memory source,
        bytes calldata payload
    ) public {
        HubSpokeStructs.FinalizeCreditPayload memory fcp = abi.decode(payload, (HubSpokeStructs.FinalizeCreditPayload));
        HubSpokeStructs.SpokeState storage spokeState = HubStorage.getSpokeState(source.chainId);
        HubSpokeStructs.Credit storage storedCredit = spokeState.credits[fcp.credit.user][fcp.credit.nonce];

        // this shouldn't happen, but check anyway
        if (storedCredit.status == HubSpokeStructs.CreditStatus.FINALIZED) {
            revert CreditAlreadyFinalized();
        }

        IWormholeTunnel wormholeTunnel = HubStorage.getAuxilaryContracts().wormholeTunnel;

        if (CommonOptimisticFinalityLogic.creditMissingOrConflicting(fcp.credit, storedCredit)) {
            // this scenario is a fraud attempt or a reverted inbound instant.
            // - if the credit is conflicting then there already was a TX from that user with that nonce.
            //   this means it got reorg'd and replaced with a different one.
            //   this couldn't have happened by accident, because the user had to replace the reorg'd TX in the mempool.
            //   because the instant message must have reverted due to user nonce being already used.
            // - if the credit is missing then the reorg'd action might have reverted without malice (ex. deposit / borrow limits exceeded)
            //   or the reorg'd action was a borrow/withdraw
            // in both cases the finalized deposit is added to Spoke reserves and can be refunded manually if need be
            // the finalized deposit is confirmed on the Spoke to unlock the finalized credit amount and add it to reserves

            if (storedCredit.createdAt != 0) {
                storedCredit.status = HubSpokeStructs.CreditStatus.LOST;
                emit HubCreditLost(source.chainId, storedCredit.user, storedCredit.token, storedCredit.creditedAmount, storedCredit.nonce);
            } else {
                // non-malicious revert or non-harming malicious revert
                // mark as refundable for manual resolution
                storedCredit.status = HubSpokeStructs.CreditStatus.REFUNDABLE;
                emit HubCreditRefundable(source.chainId, storedCredit.user, storedCredit.token, storedCredit.creditedAmount, storedCredit.nonce);
            }
        } else {
            storedCredit.status = HubSpokeStructs.CreditStatus.FINALIZED;
            emit HubCreditFinalized(source.chainId, fcp.credit.nonce);

            HubSpokeStructs.HubSpokeBalances memory balances = spokeState.balances[fcp.credit.token];
            balances.finalized += fcp.credit.creditedAmount;
            balances.unfinalized -= fcp.credit.creditedAmount;

            setSpokeBalances(
                source.chainId,
                fcp.credit.token,
                balances
            );
        }

        // a status update happens in all paths
        storedCredit.updatedAt = block.timestamp;

        {
            uint256 cost = wormholeTunnel.getMessageCost(source.chainId, SPOKE_FINALIZE_MESSAGE_GAS_LIMIT(), 0, false);
            if (msg.value < cost) {
                revert InsufficientMsgValue();
            }
        }

        IWormholeTunnel.TunnelMessage memory message;
        message.source = IWormholeTunnel.MessageSource(wormholeTunnel.chainId(), toWormholeFormat(address(this)), source.refundRecipient);
        message.target = IWormholeTunnel.MessageTarget({
        chainId: source.chainId,
            recipient: source.sender,
            selector: ISpoke.finalizeCredit.selector,
            payload: abi.encode(fcp.credit)
        });
        message.finality = IWormholeTunnel.MessageFinality.INSTANT;

        // sending msg.value instead of cost to return any overpaid amounts

        wormholeTunnel.sendEvmMessage{value: msg.value}(message, SPOKE_FINALIZE_MESSAGE_GAS_LIMIT());
    }

    function handleSendSpokeTopUp(
        uint16 spokeChainId,
        IERC20 token,
        uint256 amount,
        uint256 confirmationCost
    ) public {
        if (amount != TokenBridgeUtilities.trimDust(amount, address(token))) {
            revert InvalidAmount();
        }

        IWormholeTunnel wormholeTunnel = HubStorage.getAuxilaryContracts().wormholeTunnel;
        IAssetRegistry assetRegistry = HubStorage.getAuxilaryContracts().assetRegistry;
        IBridgeToken bt = IBridgeToken(address(token));
        HubAccountingLogic.requireRegisteredAsset(assetRegistry.getAssetId(bt.chainId(), bt.nativeContract()));
        uint256 cost = wormholeTunnel.getMessageCost(spokeChainId, SPOKE_TOP_UP_GAS_LIMIT(), confirmationCost, true);
        if (msg.value < cost) {
            revert InsufficientMsgValue();
        }

        token.forceApprove(address(wormholeTunnel), amount);

        bytes32 hubAddrb32 = toWormholeFormat(address(this));

        IWormholeTunnel.TunnelMessage memory message;
        message.source = IWormholeTunnel.MessageSource(wormholeTunnel.chainId(), hubAddrb32, hubAddrb32);
        message.target = IWormholeTunnel.MessageTarget({
            chainId: spokeChainId,
            recipient: HubStorage.getSpokeState(spokeChainId).spoke,
            selector: ISpoke.topUp.selector,
            payload: bytes("")
        });
        message.token = toWormholeFormat(address(token));
        message.amount = amount;
        message.receiverValue = confirmationCost;

        // sending the remainder of msg.value instead of cost to return any overpaid amounts
        wormholeTunnel.sendEvmMessage{value: cost}(message, SPOKE_TOP_UP_GAS_LIMIT());
    }

    function handleConfirmTopUpMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) public {
        requireNoTokenSent(token, amount);
        HubSpokeStructs.ConfirmTopUpPayload memory ctp = abi.decode(payload, (HubSpokeStructs.ConfirmTopUpPayload));
        HubSpokeStructs.HubSpokeBalances memory balances = HubStorage.getSpokeState(source.chainId).balances[ctp.token];
        balances.finalized += ctp.amount;
        setSpokeBalances(
            source.chainId,
            ctp.token,
            balances
        );
    }

    function handleConfirmFixLostCreditMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) public {
        requireNoTokenSent(token, amount);
        HubSpokeStructs.ConfirmFixLostCreditPayload memory cflcp = abi.decode(payload, (HubSpokeStructs.ConfirmFixLostCreditPayload));
        HubSpokeStructs.HubSpokeBalances memory balances = HubStorage.getSpokeState(source.chainId).balances[cflcp.token];
        balances.finalized += cflcp.amount;
        balances.unfinalized -= cflcp.amount;
        setSpokeBalances(
            source.chainId,
            cflcp.token,
            balances
        );
    }

    function setSpokeBalances(
        uint16 chainId,
        bytes32 tokenAddressOnSpoke,
        HubSpokeStructs.HubSpokeBalances memory newBalances
    ) public {

        HubStorage.getSpokeState(chainId).balances[tokenAddressOnSpoke] = newBalances;
    }
}
