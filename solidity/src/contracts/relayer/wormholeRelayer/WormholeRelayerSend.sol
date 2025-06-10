// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.19;

import {MsgValueNotEnoughForDeliveryCosts, RelayerCannotReceivePayment, TargetChainNotSupported, ParamAlwaysEmptyInSend, InvalidTargetAddress, MessageKey, VaaKey, IWormholeRelayerSend} from "../../../interfaces/relayer/IWormholeRelayerTyped.sol";

import {toWormholeFormat, fromWormholeFormat} from "@wormhole-relayer/contracts/relayer/libraries/Utils.sol";
import {DeliveryInstruction} from "../../relayer/libraries/RelayerInternalStructs.sol";
import {WormholeRelayerSerde} from "./WormholeRelayerSerde.sol";
import {WormholeRelayerStorage} from "./WormholeRelayerStorage.sol";
import {WormholeRelayerBase} from "./WormholeRelayerBase.sol";
import "@wormhole-relayer/contracts/interfaces/relayer/TypedUnits.sol";
import {ITownsqPriceOracle} from "../../../interfaces/ITownsqPriceOracle.sol";

abstract contract WormholeRelayerSend is
    WormholeRelayerBase,
    IWormholeRelayerSend
{
    using WormholeRelayerSerde for *;
    using WeiLib for Wei;
    using GasLib for Gas;
    using TargetNativeLib for TargetNative;
    using LocalNativeLib for LocalNative;

    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        TargetNative /* receiverValue */,
        LocalNative /* paymentForExtraReceiverValue */,
        bytes memory /* encodedExecutionParameters */,
        uint16 /* refundChain */,
        bytes32 /* refundAddress */,
        address deliveryProviderAddress,
        MessageKey[] memory messageKeys,
        uint8 consistencyLevel
    ) external payable returns (uint64 sequence) {
        // other values like: receiverValue, paymentForExtraReceiverValue, refundChain, refundAddress, encodedExecutionParameters
        // can be passed to this method by WormholeTunnel but can be safely ignored and won't affect business logic on WormholeTunnel side
        if (deliveryProviderAddress != address(0)) {
            revert ParamAlwaysEmptyInSend();
        }

        sequence = send(
            Send(
                targetChain,
                targetAddress,
                payload,
                messageKeys,
                consistencyLevel
            )
        );
    }

    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        VaaKey[] memory vaaKeys,
        uint8 consistencyLevel
    ) public payable returns (uint64 sequence) {
        sequence = send(
            Send(
                targetChain,
                targetAddress,
                payload,
                WormholeRelayerSerde.vaaKeyArrayToMessageKeyArray(vaaKeys),
                consistencyLevel
            )
        );
    }

    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        MessageKey[] memory messageKeys,
        uint8 consistencyLevel
    ) public payable returns (uint64 sequence) {
        sequence = send(
            Send(
                targetChain,
                targetAddress,
                payload,
                messageKeys,
                consistencyLevel
            )
        );
    }

    /*
     * Non overload logic
     */

    struct Send {
        uint16 targetChain;
        bytes32 targetAddress;
        bytes payload;
        MessageKey[] messageKeys;
        uint8 consistencyLevel;
    }

    function send(Send memory sendParams) internal returns (uint64 sequence) {
        if (sendParams.targetAddress == bytes32(0)) {
            revert InvalidTargetAddress();
        }
        // Revert if delivery provider does not support the target chain
        if (CHAIN_ID_SOLANA != sendParams.targetChain) {
            revert TargetChainNotSupported(sendParams.targetChain);
        }

        LocalNative solanaDeliveryPrice = quoteSolanaDeliveryPrice();
        LocalNative relayerReward = getRelayerReward();
        LocalNative wormholeMessageFee = getWormholeMessageFee();
        checkMsgValue(wormholeMessageFee, relayerReward, solanaDeliveryPrice);

        // Encode all relevant info the delivery provider needs to perform the delivery as requested
        bytes memory encodedInstruction = DeliveryInstruction({
            targetChain: sendParams.targetChain,
            targetAddress: sendParams.targetAddress,
            payload: sendParams.payload,
            relayerAddress: toWormholeFormat(address(this)),
            senderAddress: toWormholeFormat(msg.sender),
            messageKeys: sendParams.messageKeys
        }).encode();

        // Publish the encoded delivery instruction as a wormhole message
        // and pay the off-chain relayer its fee
        bool paymentSucceeded;
        (sequence, paymentSucceeded) = publishAndPay(
            wormholeMessageFee,
            relayerReward,
            solanaDeliveryPrice,
            encodedInstruction,
            sendParams.consistencyLevel,
            payable(WormholeRelayerStorage.getRoutingCostConfig().relayerVault)
        );

        if (!paymentSucceeded) {
            revert RelayerCannotReceivePayment();
        }
    }

    /**
     * NOTE: This is function is here for interface compatibility with original WormholeRelayer
     *
     * returns 0x0 address - there is no contract DeliveryProvider in our custom WormholeRelayer
     */
    function getDefaultDeliveryProvider()
        external
        pure
        override
        returns (address)
    {
        return address(0);
    }

    /**
     * Returns the price to relay a message to Solana chain quoted in WETH (wei).
     * To do so we must convert the price from SOL to WETH using the current oracle prices
     *
     * @return nativePriceQuote Price, in units of current chain currency, that the relayer charges to perform the relay
     */
    function quoteSolanaDeliveryPrice()
        public
        view
        override
        returns (LocalNative nativePriceQuote)
    {
        uint256 deliveryPriceSol = WormholeRelayerStorage
            .getRoutingCostConfig()
            .solanaDeliveryPrice;

        ITownsqPriceOracle.Price memory wormholeSolPrice = priceOracle.getPrice(
            solAssetId
        );
        ITownsqPriceOracle.Price memory wethPrice = priceOracle.getPrice(
            wethAssetId
        );

        uint256 deliveryPriceWeth = (deliveryPriceSol *
            wormholeSolPrice.price *
            WETH_DECIMALS) / (wethPrice.price * SOL_DECIMALS);

        return LocalNative.wrap(deliveryPriceWeth);
    }

    /**
     * NOTE: This is function is here for interface compatibility with original WormholeRelayer
     *
     * @return nativePriceQuote - price to relay a message to Solana chain including payment to the relayer on source chain (relayerReward)
     */
    function quoteDeliveryPrice(
        uint16 /* targetChain */,
        TargetNative /* receiverValue */,
        bytes memory /* encodedExecutionParameters */,
        address /* deliveryProviderAddress */
    )
        external
        view
        returns (
            LocalNative nativePriceQuote,
            bytes memory encodedExecutionInfo
        )
    {
        return (quoteSolanaDeliveryPrice() + getRelayerReward(), bytes(""));
    }

    /**
     * Returns relayer reward for relaying the message
     */
    function getRelayerReward()
        public
        view
        override
        returns (LocalNative nativePriceQuote)
    {
        uint256 relayerReward = WormholeRelayerStorage
            .getRoutingCostConfig()
            .relayerReward;
        return LocalNative.wrap(relayerReward);
    }
}
