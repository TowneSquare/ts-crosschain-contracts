// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.19;

import {IWormhole} from "@wormhole-relayer/contracts/interfaces/IWormhole.sol";
import {
    InvalidDeliveryVaa,
    InvalidEmitter,
    TargetChainIsNotThisChain,
    MessageKeysLengthDoesNotMatchMessagesLength,
    VaaKeysDoNotMatchVaas,
    MessageKey,
    VAA_KEY_TYPE,
    VaaKey,
    IWormholeRelayerDelivery,
    IWormholeRelayerSend,
    RETURNDATA_TRUNCATION_THRESHOLD
} from "../../../interfaces/relayer/IWormholeRelayerTyped.sol";
import {IWormholeReceiver} from "@wormhole-relayer/contracts/interfaces/relayer/IWormholeReceiver.sol";
import {pay, pay, min, toWormholeFormat, fromWormholeFormat, returnLengthBoundedCall, returnLengthBoundedCall} from "@wormhole-relayer/contracts/relayer/libraries/Utils.sol";
import {
    DeliveryInstruction,
    FullDeliveryInstruction
} from "../../relayer/libraries/RelayerInternalStructs.sol";
import {BytesParsing} from "@wormhole-relayer/contracts/relayer/libraries/BytesParsing.sol";
import {WormholeRelayerSerde} from "./WormholeRelayerSerde.sol";
import {
    WormholeRelayerStorage
} from "./WormholeRelayerStorage.sol";
import {WormholeRelayerBase} from "./WormholeRelayerBase.sol";
import "@wormhole-relayer/contracts/interfaces/relayer/TypedUnits.sol";
import "../../../interfaces/IWormholeTunnel.sol";


abstract contract WormholeRelayerDelivery is WormholeRelayerBase, IWormholeRelayerDelivery {
    using WormholeRelayerSerde for *;
    using BytesParsing for bytes;
    using WeiLib for Wei;
    using GasLib for Gas;
    using GasPriceLib for GasPrice;
    using TargetNativeLib for TargetNative;
    using LocalNativeLib for LocalNative;

    function deliver(
        bytes[] memory encodedVMs,
        bytes memory encodedDeliveryVAA
    ) public payable nonReentrant {
        // Parse and verify VAA containing delivery instructions, revert if invalid
        (IWormhole.VM memory vm, bool valid, string memory reason) = getWormhole().parseAndVerifyVM(encodedDeliveryVAA);
        if (!valid) {
            revert InvalidDeliveryVaa(reason);
        }

        WormholeRelayerStorage.CustomRelayerConfig memory relayerConfig = WormholeRelayerStorage.getCustomRelayerConfig();

        if (vm.emitterAddress != relayerConfig.solanaEmitterAddress) {
            revert InvalidEmitter(vm.emitterAddress, relayerConfig.solanaEmitterAddress, vm.emitterChainId);
        }
        DeliveryInstruction memory deliveryInstruction = vm.payload.decodeDeliveryInstruction();

        DeliveryVAAInfo memory deliveryVaaInfo = DeliveryVAAInfo({
            sourceChain: vm.emitterChainId,
            sourceSequence: vm.sequence,
            deliveryVaaHash: vm.hash,
            encodedVMs: encodedVMs,
            deliveryInstruction: deliveryInstruction,
            wormholeTunnel: relayerConfig.wormholeTunnel,
            gasLimit: Gas.wrap(relayerConfig.maxGasLimit)
        });

        // Revert if the target chain is not this chain
        if (getChainId() != deliveryInstruction.targetChain) {
            revert TargetChainIsNotThisChain(deliveryInstruction.targetChain);
        }

        // Revert if the VAAs delivered do not match the descriptions specified in the deliveryInstruction
        checkMessageKeysWithMessages(deliveryInstruction.messageKeys, encodedVMs);

        executeDelivery(deliveryVaaInfo);
    }

    // ------------------------------------------- PRIVATE -------------------------------------------

    struct DeliveryVAAInfo {
        uint16 sourceChain;
        uint64 sourceSequence;
        bytes32 deliveryVaaHash;
        bytes[] encodedVMs;
        DeliveryInstruction deliveryInstruction;
        address wormholeTunnel;
        Gas gasLimit;
    }

    struct DeliveryResults {
        Gas gasUsed;
        DeliveryStatus status;
        bytes additionalStatusInfo;
    }

    /**
     * Performs the following actions:
     * - Calls the `receiveWormholeMessages` method on the contract
     *     `vaaInfo.deliveryInstruction.targetAddress` (with the gas limit and value specified in
     *      vaaInfo.gasLimit  and `encodedVMs` as the input)
     *
     * - Calculates how much gas from `vaaInfo.gasLimit` is left
     *
     * @param vaaInfo struct specifying:
     *    - sourceChain chain id that the delivery originated from
     *    - sourceSequence sequence number of the delivery VAA on the source chain
     *    - deliveryVaaHash hash of delivery VAA
     *    - encodedVMs list of signed wormhole messages (VAAs)
     *    - deliveryInstruction the specific deliveryInstruction which is being executed
     *    - gasLimit the gas limit to call targetAddress with
     */
    function executeDelivery(DeliveryVAAInfo memory vaaInfo) private {
        DeliveryResults memory results;

        // Check replay protection - if so, set status to receiver failure
        if(WormholeRelayerStorage.getDeliverySuccessState().deliverySuccessBlock[vaaInfo.deliveryVaaHash] != 0) {
            results = DeliveryResults(
                Gas.wrap(0),
                DeliveryStatus.RECEIVER_FAILURE,
                bytes("Delivery already performed")
            );
        } else {
            results = executeInstruction(
                FullDeliveryInstruction({
                    sourceChain: vaaInfo.sourceChain,
                    targetAddress: toWormholeFormat(vaaInfo.wormholeTunnel),
                    payload: vaaInfo.deliveryInstruction.payload,
                    gasLimit: vaaInfo.gasLimit,
                    senderAddress: vaaInfo.deliveryInstruction.senderAddress,
                    deliveryHash: vaaInfo.deliveryVaaHash,  // this is used for replay protection (all used vaa hashes are saved in mapping)
                    additionalVaas: vaaInfo.encodedVMs
                })
            );
            setDeliveryBlock(results.status, vaaInfo.deliveryVaaHash);
        }

        emitDeliveryEvent(vaaInfo, results);
    }



    function executeInstruction(FullDeliveryInstruction memory deliveryInstruction)
        internal
        returns (DeliveryResults memory results)
    {

        Gas gasLimit = Gas.wrap(WormholeRelayerStorage.getCustomRelayerConfig().maxGasLimit);
        bool success;
        {
            address payable deliveryTarget = payable(fromWormholeFormat(deliveryInstruction.targetAddress));
            bytes memory callData = abi.encodeCall(IWormholeReceiver.receiveWormholeMessages, (
                deliveryInstruction.payload,
                deliveryInstruction.additionalVaas,
                deliveryInstruction.senderAddress,
                deliveryInstruction.sourceChain,
                deliveryInstruction.deliveryHash
            ));

            // Measure gas usage of call
            Gas preGas = Gas.wrap(gasleft());

            // Calls the `receiveWormholeMessages` endpoint on the contract `deliveryInstruction.targetAddress`
            // (with the gas limit and value specified in deliveryInstruction, and `encodedVMs` as the input)
            // If it reverts, returns the first 132 bytes of the revert message
            (success, results.additionalStatusInfo) = returnLengthBoundedCall(
                deliveryTarget,
                callData,
                gasLimit.unwrap(),
                msg.value, // pass the ether need for payments down the execution line
                RETURNDATA_TRUNCATION_THRESHOLD
            );

            Gas postGas = Gas.wrap(gasleft());

            unchecked {
                results.gasUsed = (preGas - postGas).min(gasLimit);
            }
        }

        if (success) {
            results.additionalStatusInfo = new bytes(0);
            results.status = DeliveryStatus.SUCCESS;
        } else {
            // Call to 'receiveWormholeMessages' on targetAddress reverted
            results.status = DeliveryStatus.RECEIVER_FAILURE;
        }
    }

    function emitDeliveryEvent(DeliveryVAAInfo memory vaaInfo, DeliveryResults memory results) private {
        emit Delivery(
            fromWormholeFormat(vaaInfo.deliveryInstruction.targetAddress),  // topic 0
            vaaInfo.sourceChain,     // topic 1
            vaaInfo.sourceSequence,  // topic 2
            vaaInfo.deliveryVaaHash, // here starts the log message data
            results.status,
            results.gasUsed,
            results.additionalStatusInfo
        );
    }

    function checkMessageKeysWithMessages(
        MessageKey[] memory messageKeys,
        bytes[] memory signedMessages
    ) private view {
        if (messageKeys.length != signedMessages.length) {
            revert MessageKeysLengthDoesNotMatchMessagesLength(messageKeys.length, signedMessages.length);
        }

        uint256 len = messageKeys.length;
        for (uint256 i = 0; i < len;) {
            if (messageKeys[i].keyType == VAA_KEY_TYPE) {
                IWormhole.VM memory parsedVaa = getWormhole().parseVM(signedMessages[i]);
                (VaaKey memory vaaKey,) = WormholeRelayerSerde.decodeVaaKey(messageKeys[i].encodedKey, 0);

                if (
                    vaaKey.chainId != parsedVaa.emitterChainId
                        || vaaKey.emitterAddress != parsedVaa.emitterAddress
                        || vaaKey.sequence != parsedVaa.sequence
                ) {
                    revert VaaKeysDoNotMatchVaas(uint8(i));
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    // Ensures current block number is set to implement replay protection and for indexing purposes
    function setDeliveryBlock(DeliveryStatus status, bytes32 deliveryHash) private {
        if (status == DeliveryStatus.SUCCESS) {
            WormholeRelayerStorage.getDeliverySuccessState().deliverySuccessBlock[deliveryHash] = block.number;
            // Clear out failure block if it exists from previous delivery failure
            delete WormholeRelayerStorage.getDeliveryFailureState().deliveryFailureBlock[deliveryHash];
        } else {
            WormholeRelayerStorage.getDeliveryFailureState().deliveryFailureBlock[deliveryHash] = block.number;
        }
    }
}