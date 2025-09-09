// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWormholeTunnel} from "../../../interfaces/IWormholeTunnel.sol";
import {ISpoke} from "../../../interfaces/ISpoke.sol";
import {IHub} from "../../../interfaces/IHub.sol";
import {IWETH} from "@wormhole/interfaces/IWETH.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HubSpokeStructs} from "../../../contracts/HubSpokeStructs.sol";
import {HubSpokeEvents} from "../../../contracts/HubSpokeEvents.sol";
import "@wormhole/Utils.sol";

import {CommonAccountingLogic} from "../accounting/CommonAccountingLogic.sol";
import {SpokeAccountingLogic} from "../accounting/SpokeAccountingLogic.sol";
import {CommonOptimisticFinalityLogic} from "./CommonOptimisticFinalityLogic.sol";

library SpokeOptimisticFinalityLogic {
    using SafeERC20 for IERC20;

    // events need to be in both library and contract to be picked up
    // see: https://ethereum.stackexchange.com/questions/11137/watching-events-defined-in-libraries
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
    event PossibleHubMisconfiguration(address assetSentAsWeth, address realWeth);
    // end events from HubSpokeEvents

    error CreditAlreadyFinalized();
    error CreditLimitExceeded();
    error CustodyLimitExceeded();
    error FundsAlreadyReleased();
    error InsufficientFunds();
    error InsufficientMsgValue();
    error InsufficientSpokeBalance();
    error InvalidAction();
    error InvalidAmount();
    error InvalidCostForReturnDeliveryLength();
    error InvalidReleaseFundsPayload();
    error TransactionLimitExceeded();
    error TransferFailed();
    error UnexpectedTokenReceived();

    function SPOKE_TOP_UP_GAS_LIMIT() public pure returns (uint256) {
        return 500_000;
    }

    function INSTANT_MESSAGE_FEE_PRECISION() public pure returns (uint256) {
        return 1e18;
    }

    function HUB_FINALIZE_CREDIT_GAS_LIMIT() public pure returns (uint256) {
        return 600_000;
    }

    function HUB_CONFIRM_TOP_UP_GAS_LIMIT() public pure returns (uint256) {
        return 100_000;
    }

    function setLimits(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        address _token,
        uint256 _creditLimit,
        uint256 _custodyLimit,
        uint256 _transactionLimit
    ) public {
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(_token)];
        balance.creditLimit = _creditLimit;
        balance.custodyLimit = _custodyLimit;
        balance.transactionLimit = _transactionLimit;
        balance.lastUpdated = block.timestamp;
        emit SpokeLimitsChanged(_token, _creditLimit, _custodyLimit, _transactionLimit);
    }

    function setInstantMessageFees(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        uint256 _inboundTokenInstantMessageFee,
        uint256 _outboundTokenInstantMessageFee
    ) public {
        uint256 precision = INSTANT_MESSAGE_FEE_PRECISION();
        if (_inboundTokenInstantMessageFee > precision || _outboundTokenInstantMessageFee > precision) {
            revert InvalidAmount();
        }
        ofState.inboundTokenInstantMessageFee = _inboundTokenInstantMessageFee;
        ofState.outboundTokenInstantMessageFee = _outboundTokenInstantMessageFee;
        emit SpokeFeesChanged(_inboundTokenInstantMessageFee, _outboundTokenInstantMessageFee);
    }

    function handleInstantAction(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        HubSpokeStructs.SpokeCommunicationState storage commState,
        IWETH weth,
        HubSpokeStructs.Action action,
        address asset,
        uint256 amount,
        uint256[] calldata costForReturnDelivery
    )  public {
        uint256[] memory costs;
        uint256 valueToSend = msg.value;
        {
            uint256 totalCost;
            (totalCost, costs) = getInstantActionDeliveryCosts(commState, costForReturnDelivery);
            if (msg.value < totalCost) {
                revert InsufficientMsgValue();
            }

            (action, asset, amount, valueToSend) = CommonAccountingLogic.handleInboundTokensAndAdjustAction(action, asset, amount, weth, totalCost);
        }

        if (amount == 0 || address(asset) == address(0)) {
            revert InvalidAction();
        }

        ofState.lastInstantActionNonces[msg.sender]++; // increment the nonce for this action

        if (CommonOptimisticFinalityLogic.getActionDirection(action) == HubSpokeStructs.ActionDirection.Inbound) {
            // validation checks for instant deposits and repays

            if (amount > ofState.tokenBalances[toWormholeFormat(address(asset))].transactionLimit) {
                revert TransactionLimitExceeded();
            }

            // instant token sends are sent with two messages
            if (costs.length != 2) {
                revert InvalidCostForReturnDeliveryLength();
            }

            // check credit limit
            HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(address(asset))];

            amount -= amount * ofState.inboundTokenInstantMessageFee / INSTANT_MESSAGE_FEE_PRECISION();

            HubSpokeStructs.Credit storage storedCredit = ofState.storedCredits[msg.sender][ofState.lastInstantActionNonces[msg.sender]];

            if (
                storedCredit.createdAt != 0 &&
                (
                    storedCredit.token != toWormholeFormat(address(asset)) ||
                    storedCredit.creditedAmount != amount
                )
            ) {
                // there already exists a credit under that nonce and the token or amount conflicts
                // this does not happen in a non-malicious flow
                // it means the user sent a deposit that got reorg'd and it was registered on the Hub
                // the user later replaced that deposit, because it was not re-executed with the same parameters
                // take the tokens and the ETH to recover at least some of the value the attacker was already credited with
                // these are added to the reserves on the Spoke since state is not updated
                // creditGiven was already updated when the reorg'd credit was confirmed by the Hub
                storedCredit.status = HubSpokeStructs.CreditStatus.LOST;
                storedCredit.updatedAt = block.timestamp;
                emit SpokeCreditLost(msg.sender, asset, amount, ofState.lastInstantActionNonces[msg.sender]);
                return;
            }

            // when the credit finalizes, the entire amount should be made available for new credit
            balance.unlocksPending += amount;
            balance.lastUpdated = block.timestamp;

            // balance.deposits is not updated here, because credit is given
            // credit is moved to deposits in finalizeCredit
            // only add credit if there was no reorg (credit was not created by the Hub confirmation)
            if (storedCredit.createdAt == 0) {
                balance.creditGiven += amount;
                // this check is skipped if the credit already exists, because this credit has already been processed in the Hub
                // in rare cases this can lead to credit limit being temporarily exceeded
                if (balance.creditGiven + balance.creditLost > balance.creditLimit) {
                   revert CreditLimitExceeded();
                }

                // check if the currently finalized amount plus the pending amount is under the custody limit
                if (balance.deposits + balance.unlocksPending > balance.custodyLimit) {
                    revert CustodyLimitExceeded();
                }

                storedCredit.user = toWormholeFormat(msg.sender);
                storedCredit.token = toWormholeFormat(address(asset));
                storedCredit.creditedAmount = amount;
                storedCredit.nonce = ofState.lastInstantActionNonces[msg.sender];
                storedCredit.createdAt = block.timestamp;

                emit SpokeCreditCreated(msg.sender, address(asset), amount, storedCredit.nonce);

                _sendInstantActionTunnelMessage(
                    ofState,
                    commState,
                    action,
                    storedCredit.token, // same as b32(a(asset)), but already as b32
                    amount,
                    costs[0],
                    costForReturnDelivery[0]
                );
            } else {
                // the credit has been created through Hub confirmation.
                // when it was created the amount of credit has been accounted as lost
                // this tx restores the lost tokens
                balance.creditLost -= amount;
                balance.creditGiven += amount;
            }

            // the finalize credit message is sent regardless if the credit existed before or not
            // if it did then it must have gotten reorg'd. checks for credit being identical have been made earlier.
            // when this message finalizes the credit no protocol loss will be incurred and the credit
            // will be finalized correctly in spite of the reorg
            _sendFinalizeCreditTunnelMessage(
                commState,
                storedCredit,
                costs[1],
                costForReturnDelivery[1]
            );
        } else {
            // borrow and withdraw flow

            // instant token sends are sent with one message
            if (costForReturnDelivery.length != 1) {
                revert InvalidCostForReturnDeliveryLength();
            }

            if (ofState.tokenBalances[toWormholeFormat(address(asset))].deposits < amount) {
                revert InsufficientFunds();
            }

            _sendInstantActionTunnelMessage(
                ofState,
                commState,
                action,
                toWormholeFormat(asset),
                amount,
                costs[0],
                costForReturnDelivery[0]
            );
        }
    }

    function handleReleaseFunds(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        IWETH weth,
        bytes calldata payload
    ) public {
        HubSpokeStructs.ReleaseFundsPayload memory rfp = abi.decode(payload, (HubSpokeStructs.ReleaseFundsPayload));
        if (rfp.token == bytes32(0) || rfp.amount == 0) {
            revert InvalidReleaseFundsPayload();
        }

        address user = fromWormholeFormat(rfp.user);

        if (ofState.fundReleases[user][rfp.nonce].amount != 0) {
            // there already exists a release of funds under that nonce
            // this should never happen, because SpokeFundRelease is only created in this function.
            // revert to prevent the duplicate release
            revert FundsAlreadyReleased();
        }

        if (ofState.tokenBalances[rfp.token].deposits < rfp.amount) {
            revert InsufficientFunds();
        }

        // full amount is subtracted from deposits
        // as a result, the fee is accounted towards reserves
        ofState.tokenBalances[rfp.token].deposits -= rfp.amount;
        ofState.tokenBalances[rfp.token].lastUpdated = block.timestamp;

        ofState.fundReleases[user][rfp.nonce] = HubSpokeStructs.SpokeFundRelease({
            nonce: rfp.nonce,
            user: rfp.user,
            token: rfp.token,
            amount: rfp.amount,
            releasedAt: block.timestamp
        });
        if (rfp.unwrapWeth && rfp.token == toWormholeFormat(address(weth))) {
            weth.withdraw(rfp.amount);
            (bool success,) = fromWormholeFormat(rfp.user).call{value: rfp.amount}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            address token = fromWormholeFormat(rfp.token);
            if (rfp.unwrapWeth) {
                emit PossibleHubMisconfiguration(token, address(weth));
            }
            // we default to just transferring the token if the Hub somehow messed up and requested to unwrap something other than WETH.
            // reverting here would be problematic. we can't replay this, because it's simply invalid and will not become valid later.
            // it's probably best not to revert instants on non-critical issues.
            // this should never happen anyway, because rfp.token is passed around in payloads from Spoke to Hub and back to Spoke without being changed.
            IERC20(token).safeTransfer(fromWormholeFormat(rfp.user), rfp.amount);
        }

        emit SpokeFundsReleased(fromWormholeFormat(rfp.user), fromWormholeFormat(rfp.token), rfp.amount, rfp.nonce);
    }

    function handleTopUp(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        HubSpokeStructs.SpokeCommunicationState storage commState,
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount
    ) public {
        token.safeTransferFrom(msg.sender, address(this), amount);
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(address(token))];
        balance.deposits += amount;
        balance.lastUpdated = block.timestamp;

        emit SpokeTopUpReceived(address(token), amount);

        IWormholeTunnel.TunnelMessage memory message;
        message.source.refundRecipient = source.refundRecipient;
        message.source.sender = toWormholeFormat(address(this));

        message.target.chainId = commState.hubChainId;
        message.target.recipient = commState.hubContractAddress;
        message.target.selector = IHub.confirmTopUpMessage.selector;
        message.target.payload = abi.encode(HubSpokeStructs.ConfirmTopUpPayload({
            token: toWormholeFormat(address(token)),
            amount: amount
        }));

        message.finality = IWormholeTunnel.MessageFinality.INSTANT;

        uint256 cost = commState.wormholeTunnel.getMessageCost(commState.hubChainId, HUB_CONFIRM_TOP_UP_GAS_LIMIT(), 0, false);
        commState.wormholeTunnel.sendEvmMessage{value: cost}(message, HUB_CONFIRM_TOP_UP_GAS_LIMIT());
    }

    function handleConfirmCredit(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        bytes calldata payload
    ) public {
        HubSpokeStructs.ConfirmCreditPayload memory ccp = abi.decode(payload, (HubSpokeStructs.ConfirmCreditPayload));
        address user = fromWormholeFormat(ccp.credit.user);
        HubSpokeStructs.Credit storage storedCredit = ofState.storedCredits[user][ccp.credit.nonce];
        if (CommonOptimisticFinalityLogic.creditMissingOrConflicting(ccp.credit, storedCredit)) {
            address token = fromWormholeFormat(ccp.credit.token);
            HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[ccp.credit.token];
            if (storedCredit.createdAt != 0) {
                // credit already exists with different user, token or amount
                // this means that the credit being confirmed got reorg'd out of the spoke
                // also, before the current confirmation arrived, a new credit has been given
                // the credit in the Spoke is a new credit that replaced the one that got confirmed
                // the Spoke credit got reverted when it reached the Hub (same user nonce) and is invalid
                // only the credit confirmed by the Hub actually got accounted for
                // the credit coming from the Hub is lost, but the stored credit can still finalize
                // if it finalizes, its amount will be added to reserves
                // the incoming credit will never finalize, but it's not accounted for in the Spoke
                // signal that the stored credit is Lost
                ccp.credit.status = HubSpokeStructs.CreditStatus.LOST;
                emit SpokeCreditLost(user, token, ccp.credit.creditedAmount, ccp.credit.nonce);
            } else {
                // - we don't update SpokeBalances unlocksPending or deposits
                //   if the action is non-malicious these values will be updated
                //   when the action is re-executed
                // - we don't increase the users nonce in anticipation that this was a non-malicious reorg
                //   in this case the users deposit will be re-added under the same nonce
                //   if the deposit is not re-added then the users action must have been malicious
                //   the next user action will revert on the Hub, because the Spoke will send it with
                //   a nonce that already exists on the Hub
                ccp.credit.status = HubSpokeStructs.CreditStatus.CONFIRMED;
                emit SpokeCreditCreated(user, token, ccp.credit.creditedAmount, ccp.credit.nonce);
            }

            // re-create the credit
            // regardless if the Spoke Credit is missing or conflicting, we overwrite it with what came from the Hub
            // because that's what was accounted for
            // Solidity quirk: can't use the storedCredit storage pointer for this assignment
            ccp.credit.createdAt = block.timestamp;
            ofState.storedCredits[user][ccp.credit.nonce] = ccp.credit;
            // add the amount as credit that is lost
            // credit that is conflicting is lost for sure
            // credit that is missing might still return to correct state if the same tx is re-added into a later block
            balance.creditLost += ccp.credit.creditedAmount;
            // creditGiven and unlocksPending are not updated here.
            // if there was a credit conflict then the later post-reorg credit that modified the balances
            // can still finalize. in that case, finalizeCredit() will reduce creditGiven and unlocksPending
            balance.lastUpdated = block.timestamp;
        } else {
            storedCredit.status = HubSpokeStructs.CreditStatus.CONFIRMED;
        }

        // this confirms the credit. the stored credit here always matches the incoming credit
        storedCredit.updatedAt = block.timestamp;
        emit SpokeCreditConfirmed(ccp.credit.nonce);
    }

    function handleFinalizeCredit(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        bytes calldata payload
    ) public {
        HubSpokeStructs.FinalizeCreditPayload memory fcp = abi.decode(payload, (HubSpokeStructs.FinalizeCreditPayload));
        address user = fromWormholeFormat(fcp.credit.user);
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[fcp.credit.token];
        HubSpokeStructs.Credit storage storedCredit = ofState.storedCredits[user][fcp.credit.nonce];
        if (storedCredit.status == HubSpokeStructs.CreditStatus.CONFIRMED) {
            storedCredit.status = HubSpokeStructs.CreditStatus.FINALIZED;
            storedCredit.updatedAt = block.timestamp;
            emit SpokeCreditFinalized(fcp.credit.nonce);
        } else if (storedCredit.createdAt > 0 && storedCredit.status == HubSpokeStructs.CreditStatus.PENDING) {
            // the credit has been created, but hasn't been confirmed by the Hub and hasn't been marked as LOST
            // one of two things could have happened here:
            //   - this was a failed malicious attempt where the original TX was a borrow
            //     which got replaced with a deposit or repay
            //   - this was a deposit or repay that failed for non-malicious reasons
            //     such as a crossed deposit limit or invalid repay amount
            // in both cases a manual resolution is needed
            storedCredit.status = HubSpokeStructs.CreditStatus.REFUNDABLE;
            storedCredit.updatedAt = block.timestamp;
            emit SpokeCreditRefundable(user, fromWormholeFormat(storedCredit.token), storedCredit.creditedAmount, storedCredit.nonce);
        }

        // confirmed and pending credit cases are handled above
        // if credit was lost, one of two things could have happened:
        //   - if replaced before confirmation then a new Credit was created and creditGiven was increased
        //   - if replaced after confirmation then no finalization message was sent so this function will not be called
        // this should never underflow, because we only add this when creating credit
        balance.creditGiven -= fcp.credit.creditedAmount;
        balance.lastUpdated = block.timestamp;

        balance.unlocksPending -= fcp.credit.creditedAmount;
        if (ofState.storedCredits[user][fcp.credit.nonce].status == HubSpokeStructs.CreditStatus.FINALIZED) {
            // move the amount from credit to finalized deposit
            // only account towards deposits if this is a happy path with confirmed credit
            // if the credit was missing or conflicting then the credit being finalized has not been confirmed by the Hub
            // this means that the amount should be acounted towards protocol reserves
            // in that case we have two possible scenarios. the finalized amount (now stored as reserve) can be:
            //   - refunded in case of a non-malicious Hub revert (ex. deposit bounced due to limits)
            //   - taken over to cover the loss in case of a malicious attempt
            balance.deposits += fcp.credit.creditedAmount;
        }
    }

    function handleFixLostCredit(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        HubSpokeStructs.SpokeCommunicationState storage commState,
        IERC20 token,
        uint256 amount,
        bool fromReserves
    ) public {
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(address(token))];
        if (balance.creditLost < amount) {
            revert InvalidAmount();
        }

        uint256 cost = commState.wormholeTunnel.getMessageCost(commState.hubChainId, HUB_CONFIRM_TOP_UP_GAS_LIMIT(), 0, false);

        // the cost can be covered either by passing it as msg.value or from reserves
        // either way the balance needs to exceed the cost
        if (address(this).balance < cost) {
            revert InsufficientMsgValue();
        }

        if (!fromReserves) {
            token.safeTransferFrom(msg.sender, address(this), amount);
        } else if (SpokeAccountingLogic.getReserveAmount(ofState, address(token)) < amount) {
            revert InsufficientFunds();
        }

        balance.creditLost -= amount;
        balance.deposits += amount;

        // this flow is the same as a top up confirmation
        // it just increases the Hub accounted Spoke finalized deposit balance
        // sent as an instant, because owner is assumed to not be malicious
        bytes32 spokeAddressWhFormat = toWormholeFormat(address(this));
        IWormholeTunnel.TunnelMessage memory message;
        message.source.refundRecipient = spokeAddressWhFormat;
        message.source.sender = spokeAddressWhFormat;

        message.target.chainId = commState.hubChainId;
        message.target.recipient = commState.hubContractAddress;
        message.target.selector = IHub.confirmFixLostCreditMessage.selector;
        message.target.payload = abi.encode(HubSpokeStructs.ConfirmFixLostCreditPayload({
            token: toWormholeFormat(address(token)),
            amount: amount
        }));

        message.finality = IWormholeTunnel.MessageFinality.INSTANT;

        commState.wormholeTunnel.sendEvmMessage{value: cost}(message, HUB_CONFIRM_TOP_UP_GAS_LIMIT());
    }

    function handleRefundCredit(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        address _user,
        uint256 _nonce
    ) public {
        HubSpokeStructs.Credit storage credit = ofState.storedCredits[_user][_nonce];
        if (credit.status != HubSpokeStructs.CreditStatus.REFUNDABLE) {
            // the credit has been confirmed by the Hub
            // there can be no refund
            // the user should make a withdrawal instead
            revert InvalidAction();
        }

        IERC20 token = IERC20(fromWormholeFormat(credit.token));
        if (SpokeAccountingLogic.getReserveAmount(ofState, address(token)) < credit.creditedAmount) {
            revert InsufficientFunds();
        }

        credit.status = HubSpokeStructs.CreditStatus.REFUNDED;
        token.safeTransfer(_user, credit.creditedAmount);
        emit SpokeCreditRefunded(_user, address(token), credit.creditedAmount, _nonce);
    }

    function _sendFinalizeCreditTunnelMessage(
        HubSpokeStructs.SpokeCommunicationState storage commState,
        HubSpokeStructs.Credit storage credit,
        uint256 actionCost,
        uint256 returnDeliveryCost
    ) internal {
        IWormholeTunnel.TunnelMessage memory message;
        message.source.refundRecipient = message.source.refundRecipient;
        message.source.sender = message.source.refundRecipient;
        message.source.chainId = commState.wormholeTunnel.chainId();

        message.target.chainId = commState.hubChainId;
        message.target.recipient = commState.hubContractAddress;
        message.target.selector = IHub.finalizeCreditMessage.selector;
        message.target.payload = abi.encode(HubSpokeStructs.FinalizeCreditPayload({
            credit: credit
        }));

        message.receiverValue = returnDeliveryCost;

        commState.wormholeTunnel.sendEvmMessage{value: actionCost}(
            message,
            HUB_FINALIZE_CREDIT_GAS_LIMIT()
        );
    }

    function _sendInstantActionTunnelMessage(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        HubSpokeStructs.SpokeCommunicationState storage commState,
        HubSpokeStructs.Action action,
        bytes32 asset,
        uint256 amount,
        uint256 actionCost,
        uint256 returnDeliveryCost
    ) internal {
        IWormholeTunnel.TunnelMessage memory message;

        message.source.refundRecipient = toWormholeFormat(msg.sender);
        message.source.sender = toWormholeFormat(address(this));

        message.target.chainId = commState.hubChainId;
        message.target.recipient = commState.hubContractAddress;
        message.target.selector = IHub.instantActionMessage.selector;
        message.target.payload = abi.encode(HubSpokeStructs.UserActionPayload({
            user: message.source.refundRecipient,
            action: action,
            token: asset,
            amount: amount,
            nonce: ofState.lastInstantActionNonces[msg.sender]
        }));

        message.finality = IWormholeTunnel.MessageFinality.INSTANT;
        message.receiverValue = returnDeliveryCost;
        commState.wormholeTunnel.sendEvmMessage{value: actionCost}(
            message,
            commState.defaultGasLimitRoundtrip
        );
    }

    function getInstantActionDeliveryCosts(
        HubSpokeStructs.SpokeCommunicationState storage commState,
        uint256[] calldata returnCosts
    ) public view returns (uint256 total, uint256[] memory costs) {
        // for deposit/repay flow there should be two returnCosts. the first one to send an accounting confirmation, the second one to send the finalization confirmation
        // for withdraw/borrow flow there should only be a single return cost
        costs = new uint256[](returnCosts.length);
        for (uint256 i = 0; i < returnCosts.length; i++) {
            costs[i] = commState.wormholeTunnel.getMessageCost(
                commState.hubChainId,
                commState.defaultGasLimitRoundtrip,
                returnCosts[i],
                false
            );
            total += costs[i];
        }
    }
}