// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.19;

import {
    InvalidPayloadId,
    InvalidPayloadLength,
    TooManyMessageKeys,
    MessageKey,
    VAA_KEY_TYPE,
    VaaKey
} from "../../../interfaces/relayer/IWormholeRelayerTyped.sol";
import { DeliveryInstruction } from "../../relayer/libraries/RelayerInternalStructs.sol";
import {BytesParsing} from "@wormhole-relayer/contracts/relayer/libraries/BytesParsing.sol";
import "@wormhole-relayer/contracts/interfaces/relayer/TypedUnits.sol";


library WormholeRelayerSerde {
    using BytesParsing for bytes;
    using WeiLib for Wei;
    using GasLib for Gas;

    uint8 private constant PAYLOAD_ID_DELIVERY_INSTRUCTION = 1;

    uint256 constant VAA_KEY_TYPE_LENGTH = 2 + 32 + 8;

    // ---------------------- Internal encoding/decoding functions -----------------------
    // These functions are intended for use within the library and by contracts that use the library.

    function encode(DeliveryInstruction memory strct)
        internal
        pure
        returns (bytes memory encoded)
    {
        encoded = abi.encodePacked(
            PAYLOAD_ID_DELIVERY_INSTRUCTION,
            strct.targetChain,
            strct.targetAddress,
            encodeBytes(strct.payload)
        );
        encoded = abi.encodePacked(
            encoded,
            strct.relayerAddress,
            strct.senderAddress,
            encodeMessageKeyArray(strct.messageKeys)
        );
    }

    function decodeDeliveryInstruction(bytes memory encoded)
        internal
        pure
        returns (DeliveryInstruction memory strct)
    {
        uint256 offset = checkUint8(encoded, 0, PAYLOAD_ID_DELIVERY_INSTRUCTION);

        (strct.targetChain, offset) = encoded.asUint16Unchecked(offset);
        (strct.targetAddress, offset) = encoded.asBytes32Unchecked(offset);
        (strct.payload, offset) = decodeBytes(encoded, offset);
        (strct.relayerAddress, offset) = encoded.asBytes32Unchecked(offset);
        (strct.senderAddress, offset) = encoded.asBytes32Unchecked(offset);
        (strct.messageKeys, offset) = decodeMessageKeyArray(encoded, offset);

        checkLength(encoded, offset);
    }

    function vaaKeyArrayToMessageKeyArray(VaaKey[] memory vaaKeys)
        internal
        pure
        returns (MessageKey[] memory msgKeys)
    {
        msgKeys = new MessageKey[](vaaKeys.length);
        uint256 len = vaaKeys.length;
        for (uint256 i = 0; i < len;) {
            msgKeys[i] = MessageKey(VAA_KEY_TYPE, encodeVaaKey(vaaKeys[i]));
            unchecked {
                ++i;
            }
        }
    }

    function encodeMessageKey(
        MessageKey memory msgKey
    ) internal pure returns (bytes memory encoded) {
        if (msgKey.keyType == VAA_KEY_TYPE) {
            // known length
            encoded = abi.encodePacked(msgKey.keyType, msgKey.encodedKey);
        } else {
            encoded = abi.encodePacked(msgKey.keyType, encodeBytes(msgKey.encodedKey));
        }
    }

    function decodeMessageKey(
        bytes memory encoded,
        uint256 startOffset
    ) internal pure returns (MessageKey memory msgKey, uint256 offset) {
        (msgKey.keyType, offset) = encoded.asUint8Unchecked(startOffset);
        if (msgKey.keyType == VAA_KEY_TYPE) {
            (msgKey.encodedKey, offset) = encoded.sliceUnchecked(offset, VAA_KEY_TYPE_LENGTH);
        } else {
            (msgKey.encodedKey, offset) = decodeBytes(encoded, offset);
        }
    }

    function encodeVaaKey(VaaKey memory vaaKey) internal pure returns (bytes memory encoded) {
        encoded = abi.encodePacked(vaaKey.chainId, vaaKey.emitterAddress, vaaKey.sequence);
    }

    function decodeVaaKey(
        bytes memory encoded,
        uint256 startOffset
    ) internal pure returns (VaaKey memory vaaKey, uint256 offset) {
        offset = startOffset;
        (vaaKey.chainId, offset) = encoded.asUint16Unchecked(offset);
        (vaaKey.emitterAddress, offset) = encoded.asBytes32Unchecked(offset);
        (vaaKey.sequence, offset) = encoded.asUint64Unchecked(offset);
    }

    function encodeMessageKeyArray(MessageKey[] memory msgKeys)
        internal
        pure
        returns (bytes memory encoded)
    {
        uint256 len = msgKeys.length;
        if (len > type(uint8).max) {
            revert TooManyMessageKeys(len);
        }
        encoded = abi.encodePacked(uint8(msgKeys.length));
        for (uint256 i = 0; i < len;) {
            encoded = abi.encodePacked(encoded, encodeMessageKey(msgKeys[i]));
            unchecked {
                ++i;
            }
        }
    }

    function decodeMessageKeyArray(
        bytes memory encoded,
        uint256 startOffset
    ) internal pure returns (MessageKey[] memory msgKeys, uint256 offset) {
        uint8 msgKeysLength;
        (msgKeysLength, offset) = encoded.asUint8Unchecked(startOffset);
        msgKeys = new MessageKey[](msgKeysLength);
        for (uint256 i = 0; i < msgKeysLength;) {
            (msgKeys[i], offset) = decodeMessageKey(encoded, offset);
            unchecked {
                ++i;
            }
        }
    }

    // ------------------------------------------ private --------------------------------------------

    function encodeBytes(bytes memory payload) private pure returns (bytes memory encoded) {
        //casting payload.length to uint32 is safe because you'll be hard-pressed to allocate 4 GB of
        //  EVM memory in a single transaction
        encoded = abi.encodePacked(uint32(payload.length), payload);
    }

    function decodeBytes(
        bytes memory encoded,
        uint256 startOffset
    ) private pure returns (bytes memory payload, uint256 offset) {
        uint32 payloadLength;
        (payloadLength, offset) = encoded.asUint32Unchecked(startOffset);
        (payload, offset) = encoded.sliceUnchecked(offset, payloadLength);
    }

    function checkUint8(
        bytes memory encoded,
        uint256 startOffset,
        uint8 expectedPayloadId
    ) private pure returns (uint256 offset) {
        uint8 parsedPayloadId;
        (parsedPayloadId, offset) = encoded.asUint8Unchecked(startOffset);
        if (parsedPayloadId != expectedPayloadId) {
            revert InvalidPayloadId(parsedPayloadId, expectedPayloadId);
        }
    }

    function checkLength(bytes memory encoded, uint256 expected) private pure {
        if (encoded.length != expected) {
            revert InvalidPayloadLength(encoded.length, expected);
        }
    }
}
