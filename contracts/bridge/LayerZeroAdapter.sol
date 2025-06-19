// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ILayerZeroEndpointV2, MessagingParams, MessagingReceipt, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OApp, MessagingFee, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { ILayerZeroReceiver, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

import "./interfaces/IBridgeAdapter.sol";
import "./interfaces/IBridgeRouter.sol";
import "./libraries/Messages.sol";

contract LayerZeroAdapter is IBridgeAdapter, Ownable, AccessControlDefaultAdminRules, OApp {
    bytes32 public constant override MANAGER_ROLE = keccak256("MANAGER");
    using OptionsBuilder for bytes;
    using SafeCast for uint256;
    using SafeCast for uint32;

    struct lzAdapterParams {
        bool isAvailable;
        uint32 lzChainId;
        bytes32 adapterAddress;
    }

    mapping(uint16 towneSquareChainId => lzAdapterParams) internal towneSquareChainIdToLayerZeroAdapter;
    mapping(uint32 layerZeroChainId => uint16 towneSquareChainId) internal layerZeroChainIdTotowneSquareChainId;

    IBridgeRouter public immutable bridgeRouter;

    event ReceiveMessage(bytes32 indexed messageId, bytes32 adapterAddress);

    modifier onlyBridgeRouter() {
        if (msg.sender != address(bridgeRouter)) revert InvalidBridgeRouter(msg.sender);
        _;
    }

    constructor(
        address admin,
        address _endpoint,
        IBridgeRouter bridgeRouter_
    ) Ownable(admin) OApp(_endpoint, admin) AccessControlDefaultAdminRules(1 days, admin) {
        bridgeRouter = bridgeRouter_;
        _grantRole(MANAGER_ROLE, admin);
    }

    function sendMessage(Messages.MessageToSend memory message) external payable override onlyBridgeRouter {
        // get chain adapter if available
        (uint32 lzChainId, bytes32 adapterAddress) = getChainAdapter(message.destinationChainId);

        // prepare payload by adding metadata
        bytes memory payloadWithMetadata = Messages.encodePayloadWithMetadata(message);
        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(message.params.gasLimit.toUint128(), message.params.receiverValue.toUint128())
            .addExecutorLzComposeOption(0, message.params.gasLimit.toUint128(), 0);

        Messages.MessagePayload memory messagePayload = Messages.decodeActionPayload(message.payload);

        // send using layerZero ENdpoint
        MessagingReceipt memory receipt = endpoint.send{ value: msg.value }(
            MessagingParams(lzChainId, adapterAddress, payloadWithMetadata, options, false),
            Messages.convertGenericAddressToEVMAddress(messagePayload.userAddress)
        );

        emit SendMessage(receipt.guid, message);
    }

    function getSendFee(Messages.MessageToSend memory message) external view override returns (uint256 fee) {
        // get chain adapter if available
        (uint32 lzChainId, bytes32 adapterAddress) = getChainAdapter(message.destinationChainId);

        // get cost of message delivery
        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(message.params.gasLimit.toUint128(), message.params.receiverValue.toUint128())
            .addExecutorLzComposeOption(0, message.params.gasLimit.toUint128(), 0);
        // prepare payload by adding metadata
        bytes memory payloadWithMetadata = Messages.encodePayloadWithMetadata(message);
        MessagingFee memory messagingFee = endpoint.quote(
            MessagingParams(lzChainId, adapterAddress, payloadWithMetadata, options, false),
            msg.sender
        );
        fee = messagingFee.nativeFee;
    }

    function getChainAdapter(uint16 chainId) public view returns (uint32 lzChainId, bytes32 adapterAddress) {
        lzAdapterParams memory chainAdapter = towneSquareChainIdToLayerZeroAdapter[chainId];
        if (!chainAdapter.isAvailable) revert ChainUnavailable(chainId);

        lzChainId = chainAdapter.lzChainId;
        adapterAddress = chainAdapter.adapterAddress;
    }

    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) public payable override {
        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }

    function addChain(
        uint16 towneSquareChainId,
        uint32 lzChainId,
        bytes32 adapterAddress
    ) external onlyRole(MANAGER_ROLE) {
        // check if chain is already added
        bool isAvailable = isChainAvailable(towneSquareChainId);
        if (isAvailable) revert ChainAlreadyAdded(towneSquareChainId);

        // add chain
        towneSquareChainIdToLayerZeroAdapter[towneSquareChainId] = lzAdapterParams({
            isAvailable: true,
            lzChainId: lzChainId,
            adapterAddress: adapterAddress
        });
        layerZeroChainIdTotowneSquareChainId[lzChainId] = towneSquareChainId;
        _setPeer(lzChainId, adapterAddress);
    }

    function removeChain(uint16 towneSquareChainId) external onlyRole(MANAGER_ROLE) {
        // get chain adapter if available
        (uint32 lzChainId, ) = getChainAdapter(towneSquareChainId);

        // remove chain
        delete towneSquareChainIdToLayerZeroAdapter[towneSquareChainId];
        delete layerZeroChainIdTotowneSquareChainId[lzChainId];
    }

    function isChainAvailable(uint16 chainId) public view override returns (bool) {
        return towneSquareChainIdToLayerZeroAdapter[chainId].isAvailable;
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata message,
        address /*executor*/, // Executor address as specified by the OApp.
        bytes calldata /*_extraData*/ // Any extra data or options to trigger on receipt.
    ) internal override {
        // Decode the payload to get the message
        uint16 towneSquareChainId = layerZeroChainIdTotowneSquareChainId[_origin.srcEid];
        (uint32 lzChainId, bytes32 adapterAddress) = getChainAdapter(towneSquareChainId);
        if (_origin.srcEid != lzChainId) revert ChainUnavailable(towneSquareChainId);
        if (adapterAddress != _origin.sender) revert InvalidMessageSender(_origin.sender);
        (Messages.MessageMetadata memory metadata, bytes memory messagePayload) = Messages.decodePayloadWithMetadata(
            message
        );

        Messages.MessageReceived memory messageReceived = Messages.MessageReceived({
            messageId: _guid,
            sourceChainId: towneSquareChainId,
            sourceAddress: metadata.sender,
            handler: metadata.handler,
            payload: messagePayload,
            returnAdapterId: metadata.returnAdapterId,
            returnGasLimit: metadata.returnGasLimit
        });
        bridgeRouter.receiveMessage{ value: msg.value }(messageReceived);

        emit ReceiveMessage(_guid, adapterAddress);
    }

    function owner() public view virtual override(AccessControlDefaultAdminRules, Ownable) returns (address) {
        return AccessControlDefaultAdminRules.owner();
    }
}
