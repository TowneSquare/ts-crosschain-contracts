// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.19;

import "@wormhole-relayer/contracts/interfaces/relayer/TypedUnits.sol";
import "../../../interfaces/relayer/IWormholeRelayerTyped.sol";

struct DeliveryInstruction {
    uint16 targetChain;     // target chain for this message
    bytes32 targetAddress;  // target contract address that a relayer contract will call and pass the VAAs 
    bytes payload;          // tunnel message
    bytes32 relayerAddress; // custom relayer address who sent the message
    bytes32 senderAddress;  // sender from source chain (spoke)
    MessageKey[] messageKeys; // message keys as vaa keys of VAAs attached to this instruction
}

struct FullDeliveryInstruction {
  uint16 sourceChain;
  bytes32 targetAddress;
  bytes payload;
  Gas gasLimit;
  bytes32 senderAddress;
  bytes32 deliveryHash;
  bytes[] additionalVaas;
}
