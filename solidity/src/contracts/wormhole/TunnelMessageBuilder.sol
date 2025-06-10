// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWormholeTunnel} from "../../interfaces/IWormholeTunnel.sol";
import "@wormhole/Utils.sol";

library TunnelMessageBuilder {
    error InvalidInput();

    function createMessage(
        address addressFrom,
        address addressTo,
        uint16 targetChainId
    ) public pure returns (IWormholeTunnel.TunnelMessage memory message) {
        return createMessage(toWormholeFormat(addressFrom), toWormholeFormat(addressTo), targetChainId);
    }

    function createMessage(
        bytes32 addressFrom,
        bytes32 addressTo,
        uint16 targetChainId
    ) public pure returns (IWormholeTunnel.TunnelMessage memory message) {
        if (addressFrom == bytes32(0) || addressTo == bytes32(0) || targetChainId == 0) {
            revert InvalidInput();
        }
        message = IWormholeTunnel.TunnelMessage({
            source: IWormholeTunnel.MessageSource({
                chainId: 0, // this is overwritten with the correct chainId in WormholeTunnel::_sendMessage
                sender: bytes32(0), // this is overwritten with the correct sender in WormholeTunnel::_sendMessage
                refundRecipient: addressFrom
            }),
            target: IWormholeTunnel.MessageTarget({
                chainId: targetChainId,
                recipient: addressTo,
                selector: bytes4(0),
                payload: bytes("")
            }),
            token: bytes32(0),
            amount: 0,
            receiverValue: 0,
            finality: IWormholeTunnel.MessageFinality.FINALIZED
        });
    }

    function addTokenTransferToMessage(IWormholeTunnel.TunnelMessage memory message, IERC20 token, uint256 amount) public pure returns (IWormholeTunnel.TunnelMessage memory) {
        if (address(token) == address(0) || amount == 0) {
            revert InvalidInput();
        }
        message.token = toWormholeFormat(address(token));
        message.amount = amount;
        return message;
    }

    function addReceiverValueToMessage(IWormholeTunnel.TunnelMessage memory message, uint256 receiverValue) public pure returns (IWormholeTunnel.TunnelMessage memory) {
        if (receiverValue == 0) {
            revert InvalidInput();
        }
        message.receiverValue = receiverValue;
        return message;
    }

    function callEvmContract(
        address from,
        address contractAddress,
        bytes4 selector,
        bytes memory payload,
        uint16 targetChainId
    ) public pure returns (IWormholeTunnel.TunnelMessage memory message) {
        return callContract(toWormholeFormat(from), toWormholeFormat(contractAddress), selector, payload, targetChainId);
    }

    function callContract(
        bytes32 from,
        bytes32 contractAddress,
        bytes4 selector,
        bytes memory payload,
        uint16 targetChainId
    ) public pure returns (IWormholeTunnel.TunnelMessage memory message) {
        message = createMessage(from, contractAddress, targetChainId);
        if (selector == bytes4(0)) {
            revert InvalidInput();
        }
        message.target.selector = selector;
        message.target.payload = payload;
    }

    function sendTokenAndEtherToAddress(
        bytes32 addressFrom,
        bytes32 addressTo,
        uint16 targetChainId,
        IERC20 token,
        uint256 amount,
        uint256 receiverValue
    ) public pure returns (IWormholeTunnel.TunnelMessage memory message) {
        message = createMessage(addressFrom, addressTo, targetChainId);
        bool valid = false;
        if (address(token) != address(0)) {
            message = addTokenTransferToMessage(message, token, amount);
            valid = true;
        }
        if (receiverValue > 0) {
            message = addReceiverValueToMessage(message, receiverValue);
            valid = true;
        }

        if (!valid) {
            revert InvalidInput();
        }
    }
}
