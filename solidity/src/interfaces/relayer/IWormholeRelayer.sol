// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

/**
 * @title WormholeRelayer
 * @author 
 * @notice This project allows developers to build cross-chain applications powered by Wormhole without needing to 
 * write and run their own relaying infrastructure
 * 
 * We implement the IWormholeRelayer interface that allows users to request a delivery provider to relay a payload (and/or additional messages) 
 * to a chain and address of their choice.
 *
 */

/**
 * @notice of IWormholeRelayer.sol vs IWormholeRelayerTyped.sol
 * They define the same interfaces, structs, and functions but with different types (raw vs wrapped types)
 * Differences:
 * - `IWormholeRelayerTyped.sol` introduces custom typed units like `LocalNative` and `Gas` which replace `uint256` (used in `IWormholeRelayer`)
 *    in relevant places for better type safety.
 * - These custom types lead to changes in function signatures, event definitions, and error declarations.
 * - `IWormholeRelayerTyped.sol` also uses a more recent version of Solidity (0.8.19). 
 */

/**
 * @notice VaaKey identifies a wormhole message
 *
 * @custom:member chainId Wormhole chain ID of the chain where this VAA was emitted from
 * @custom:member emitterAddress Address of the emitter of the VAA, in Wormhole bytes32 format
 * @custom:member sequence Sequence number of the VAA
 */
struct VaaKey {
    uint16 chainId;
    bytes32 emitterAddress;
    uint64 sequence;
}

// 0-127 are reserved for standardized KeyTypes, 128-255 are for custom use
uint8 constant VAA_KEY_TYPE = 1;
uint8 constant CCTP_KEY_TYPE = 2;

struct MessageKey {
    uint8 keyType; // 0-127 are reserved for standardized KeyTypes, 128-255 are for custom use
    bytes encodedKey;
}

interface IWormholeRelayerBase {
    event SendEvent(uint64 indexed sequence, uint256 deliveryQuote);

    function getRegisteredWormholeRelayerContract(uint16 chainId) external view returns (bytes32);

    /**
     * @notice Returns true if a delivery has been attempted for the given deliveryHash
     * Note: invalid deliveries where the tx reverts are not considered attempted
     */
    function deliveryAttempted(bytes32 deliveryHash) external view returns (bool attempted);

    /**
     * @notice block number at which a delivery was successfully executed
     */
    function deliverySuccessBlock(bytes32 deliveryHash) external view returns (uint256 blockNumber);

    /**
     * @notice block number of the latest attempt to execute a delivery that failed
     */
    function deliveryFailureBlock(bytes32 deliveryHash) external view returns (uint256 blockNumber);
}

/**
 * @title IWormholeRelayerSend
 * @notice The interface to request deliveries
 */
interface IWormholeRelayerSend is IWormholeRelayerBase {
    /**
     * @notice Publishes an instruction for the relayer
     * to relay a payload and VAAs specified by `vaaKeys` to the address `targetAddress` on chain `targetChain` 
     * 
     * `targetAddress` must implement the IWormholeReceiver interface
     * 
     * @param targetChain in Wormhole Chain ID format
     * @param targetAddress address to call on targetChain (that implements IWormholeReceiver), in Wormhole bytes32 format
     * @param payload arbitrary bytes to pass in as parameter in call to `targetAddress`
     * @param vaaKeys Additional VAAs to pass in as parameter in call to `targetAddress`
     * @param consistencyLevel Consistency level with which to publish the delivery instructions - see 
     *        https://book.wormhole.com/wormhole/3_coreLayerContracts.html?highlight=consistency#consistency-levels
     * @return sequence sequence number of published VAA containing delivery instructions
     */
    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        VaaKey[] memory vaaKeys,
        uint8 consistencyLevel
    ) external payable returns (uint64 sequence);

    /**
     * @notice Publishes an instruction for the relayer
     * to relay a payload and VAAs specified by `vaaKeys` to the address `targetAddress` on chain `targetChain` 
     * 
     * `targetAddress` must implement the IWormholeReceiver interface
     * 
     * Note: MessageKeys can specify wormhole messages (VaaKeys) or other types of messages (ex. USDC CCTP attestations). Ensure the selected 
     * relayer supports all the MessageKey.keyType values specified or it will not be delivered!
     * 
     * @param targetChain in Wormhole Chain ID format
     * @param targetAddress address to call on targetChain (that implements IWormholeReceiver), in Wormhole bytes32 format
     * @param payload arbitrary bytes to pass in as parameter in call to `targetAddress`
     * @param messageKeys Additional messagess to pass in as parameter in call to `targetAddress`
     * @param consistencyLevel Consistency level with which to publish the delivery instructions - see 
     *        https://book.wormhole.com/wormhole/3_coreLayerContracts.html?highlight=consistency#consistency-levels
     * @return sequence sequence number of published VAA containing delivery instructions
     */
    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        MessageKey[] memory messageKeys,
        uint8 consistencyLevel
    ) external payable returns (uint64 sequence);

    /**
     * NOTE: This is function is here for interface compatibility with original WormholeRelayer, it will call send(..) above
     *
     * @notice Publishes an instruction for the relayer
     * to relay a payload and VAAs specified by `vaaKeys` to the address `targetAddress` on chain `targetChain`
     *
     * `targetAddress` must implement the IWormholeReceiver interface
     *
     * Note: MessageKeys can specify wormhole messages (VaaKeys) or other types of messages (ex. USDC CCTP attestations). Ensure the selected
     * relayer supports all the MessageKey.keyType values specified or it will not be delivered!
     *
     * @param targetChain in Wormhole Chain ID format
     * @param targetAddress address to call on targetChain (that implements IWormholeReceiver), in Wormhole bytes32 format
     * @param payload arbitrary bytes to pass in as parameter in call to `targetAddress`
     * @param receiverValue - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param paymentForExtraReceiverValue - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param encodedExecutionParameters - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param refundChain - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param refundAddress - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param deliveryProviderAddress - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param relayerAddress - UNUSED - LEFT FOR COMPATIBILITY WITH GENERIC WORMHOLE RELAYER
     * @param messageKeys Additional messagess to pass in as parameter in call to `targetAddress`
     * @param consistencyLevel Consistency level with which to publish the delivery instructions - see
     *        https://book.wormhole.com/wormhole/3_coreLayerContracts.html?highlight=consistency#consistency-levels
     * @return sequence sequence number of published VAA containing delivery instructions
     */
    function send(
        uint16 targetChain,
        bytes32 targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 paymentForExtraReceiverValue,
        bytes memory encodedExecutionParameters,
        uint16 refundChain,
        bytes32 refundAddress,
        address deliveryProviderAddress,
        address relayerAddress,
        MessageKey[] memory messageKeys,
        uint8 consistencyLevel
    ) external payable returns (uint64 sequence);

    /**
     * Returns the price to relay a message to Solana chain.
     * It includes Solana gas fee, evm wormhole fee and relayer reward
     *
     * @return nativePriceQuote Total cost in Wei of fees on source chain gas gas + fees needed on target chain
     */
    function quoteSolanaDeliveryPrice() external view returns (uint256 nativePriceQuote);

    /**
     * NOTE: This is function is here for interface compatibility with original WormholeRelayer
     *
     * Returns the price to relay a message to Solana chain.
     * It includes Solana gas fee, evm wormhole fee and relayer reward
     *
     * @return nativePriceQuote Total cost in Wei of fees on source chain gas gas + fees needed on target chain
     */
    function quoteDeliveryPrice(
        uint16 targetChain,
        uint256 receiverValue,
        bytes memory encodedExecutionParameters,
        address deliveryProviderAddress
    ) external view returns (uint256 nativePriceQuote, bytes memory encodedExecutionInfo);

    /**
     * Returns relayer reward for relaying the message 
     */
    function getRelayerReward() external view returns (uint256 nativePriceQuote);

    /**
     * NOTE: This is function is here for interface compatibility with original WormholeRelayer
     *
     * returns 0x0 address - there is no contract DeliveryProvider in our custom WormholeRelayer
     */
    function getDefaultDeliveryProvider() external view returns (address deliveryProvider);
}

/**
 * @title IWormholeRelayerDelivery
 * @notice The interface to execute deliveries. Only relevant for Delivery Providers 
 */
interface IWormholeRelayerDelivery is IWormholeRelayerBase {
    enum DeliveryStatus {
        SUCCESS,
        RECEIVER_FAILURE
    }

    /**
     * @custom:member recipientContract - The target contract address
     * @custom:member sourceChain - The chain which this delivery was requested from (in wormhole
     *     ChainID format)
     * @custom:member sequence - The wormhole sequence number of the delivery VAA on the source chain
     *     corresponding to this delivery request
     * @custom:member deliveryVaaHash - The hash of the delivery VAA corresponding to this delivery
     *     request
     * @custom:member gasUsed - The amount of gas that was used to call your target contract 
     * @custom:member status:
     *   - RECEIVER_FAILURE, if the target contract reverts
     *   - SUCCESS, if the target contract doesn't revert
     * @custom:member additionalStatusInfo:
     *   - If status is SUCCESS, then this is empty.
     *   - If status is RECEIVER_FAILURE, this is `RETURNDATA_TRUNCATION_THRESHOLD` bytes of the
     *       return data (i.e. potentially truncated revert reason information).
     */
    event Delivery(
        address indexed recipientContract,
        uint16 indexed sourceChain,
        uint64 indexed sequence,
        bytes32 deliveryVaaHash,
        DeliveryStatus status,
        uint256 gasUsed,
        bytes additionalStatusInfo
    );

/**
     * @notice The delivery provider calls `deliver` to relay messages as described by one delivery instruction
     * 
     * The delivery provider must pass in the specified (by VaaKeys[]) signed wormhole messages (VAAs) from the source chain
     * as well as the signed wormhole message with the delivery instructions (the delivery VAA)
     *
     * The messages will be relayed to the target address (with the specified gas limit and receiver value) if the following checks are met:
     * - the delivery VAA has a valid signature
     * - the delivery VAA's emitter is one of these WormholeRelayer contracts
     * - the off-chain relayer passed in at least enough of this chain's currency as msg.value
     * - the instruction's target chain is this chain
     * - the relayed signed VAAs match the descriptions in container.messages (the VAA hashes match, or the emitter address, sequence number pair matches, depending on the description given)
     *
     * @param encodedVMs - An array of signed wormhole messages (all from the same source chain transaction)
     * @param encodedDeliveryVAA - Signed wormhole message from the source chain's WormholeRelayer
     *     contract with payload being the encoded delivery instruction container
     */
    function deliver(
        bytes[] memory encodedVMs,
        bytes memory encodedDeliveryVAA
    ) external payable;
}

interface IWormholeRelayer is IWormholeRelayerDelivery, IWormholeRelayerSend {}

/*
 *  Errors thrown by IWormholeRelayer contract
 */

// Bound chosen by the following formula: `memoryWord * 4 + selectorSize`.
// This means that an error identifier plus four fixed size arguments should be available to developers.
// In the case of a `require` revert with error message, this should provide 2 memory word's worth of data.
uint256 constant RETURNDATA_TRUNCATION_THRESHOLD = 132;

//When msg.value was not equal to delivery price + extra payments (wormhole fee)
error MsgValueNotEnoughForDeliveryCosts(uint256 msgValue, uint256 totalFee);
error RelayerPaymentTooSmall(uint256 expectedPayment, uint256 receivedPayment);

error TargetChainNotSupported(uint16 chainId);
error RelayerCannotReceivePayment();

//When calling `delivery()` a second time even though a delivery is already in progress
error ReentrantDelivery(address msgSender, address lockedBy);

error InvalidPayloadId(uint8 parsed, uint8 expected);
error InvalidPayloadLength(uint256 received, uint256 expected);
error TooManyMessageKeys(uint256 numMessageKeys);

error InvalidDeliveryVaa(string reason);
//When the delivery VAA (signed wormhole message with delivery instructions) was not emitted by the
//  registered WormholeRelayer contract
error InvalidEmitter(bytes32 emitter, bytes32 registered, uint16 chainId);
error MessageKeysLengthDoesNotMatchMessagesLength(uint256 keys, uint256 vaas);
error VaaKeysDoNotMatchVaas(uint8 index);

//When trying to relay a `DeliveryInstruction` to any other chain but the one it was specified for
error TargetChainIsNotThisChain(uint16 targetChain);

//When a bytes32 field can't be converted into a 20 byte EVM address, because the 12 padding bytes
//  are non-zero (duplicated from Utils.sol)
error NotAnEvmAddress(bytes32);

error ParamAlwaysEmptyInSend();

error InvalidTargetAddress();
