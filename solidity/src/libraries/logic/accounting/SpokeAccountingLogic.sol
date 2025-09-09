// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@wormhole/Utils.sol";

import {IWormholeTunnel} from "../../../interfaces/IWormholeTunnel.sol";
import {IHub} from "../../../interfaces/IHub.sol";

import {HubSpokeStructs} from "../../../contracts/HubSpokeStructs.sol";

library SpokeAccountingLogic {
    using SafeERC20 for IERC20;

    uint256 public constant REQUEST_PAIRING_GAS_LIMIT = 100_000;

    error InsufficientFunds();
    error InsufficientMsgValue();
    error TransferFailed();
    error ZeroAddress();

    // events need to be in both library and contract to be picked up
    // see: https://ethereum.stackexchange.com/questions/11137/watching-events-defined-in-libraries
    event ReservesWithdrawn(address indexed asset, uint256 amount, address destination);
    // end events from HubSpokeEvents

    function getReserveAmount(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        address asset
    ) public view returns (uint256) {
        HubSpokeStructs.SpokeBalances storage balance = ofState.tokenBalances[toWormholeFormat(address(asset))];
        return IERC20(asset).balanceOf(address(this)) - balance.deposits - balance.creditGiven;
    }

    function withdrawReserves(
        HubSpokeStructs.SpokeOptimisticFinalityState storage ofState,
        address asset,
        uint256 amount,
        address recipient
    ) public {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        if (asset == address(0)) {
            if (address(this).balance < amount) {
                revert InsufficientFunds();
            }
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            if (amount > getReserveAmount(ofState, asset)) {
                revert InsufficientFunds();
            }
            IERC20(asset).safeTransfer(recipient, amount);
        }

        emit ReservesWithdrawn(asset, amount, recipient);
    }

    function getPairingCost(
        HubSpokeStructs.SpokeCommunicationState storage commState
    ) public view returns (uint256) {
        return commState.wormholeTunnel.getMessageCost(
            commState.hubChainId,
            REQUEST_PAIRING_GAS_LIMIT,
            0, // no return message, so no ETH sent to the Hub
            false // no token transfer
        );
    }

    function handlePairingRequest(
        HubSpokeStructs.SpokeCommunicationState storage commState,
        bytes32 userId
    ) public {
        uint256 cost = getPairingCost(commState);

        if (msg.value < cost) {
            revert InsufficientMsgValue();
        }

        bytes32 senderWhFormat = toWormholeFormat(msg.sender);
        IWormholeTunnel.TunnelMessage memory message;
        message.source.refundRecipient = senderWhFormat;
        message.source.sender = toWormholeFormat(address(this));
        message.source.chainId = commState.wormholeTunnel.chainId();

        message.target.chainId = commState.hubChainId;
        message.target.recipient = commState.hubContractAddress;
        message.target.selector = IHub.pairingRequestMessage.selector;
        message.target.payload = abi.encode(HubSpokeStructs.RequestPairingPayload({
            newAccount: senderWhFormat,
            userId: userId
        }));
        message.finality = IWormholeTunnel.MessageFinality.INSTANT;

        commState.wormholeTunnel.sendEvmMessage{value: cost}(
            message,
            REQUEST_PAIRING_GAS_LIMIT
        );
    }
}