// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { CCIPReceiver } from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import "./interfaces/IBridgeAdapter.sol";
import "./interfaces/IBridgeRouter.sol";
import "./libraries/Messages.sol";

abstract contract CCIPAdapter is IBridgeAdapter, CCIPReceiver, AccessControlDefaultAdminRules {
    bytes32 public constant override MANAGER_ROLE = keccak256("MANAGER");

    error UnsupportedReceiverValue();

    struct CCIPAdapterParams {
        bool isAvailable;
        uint64 ccipChainId;
        bytes32 adapterAddress;
    }

    mapping(uint16 townSqChainId => CCIPAdapterParams) internal townSqChainIdToCCIPAdapter;
    mapping(uint64 ccipChainId => uint16 townSqChainId) internal ccipChainIdTotownSqChainId;

    IRouterClient public immutable ccipRouter;
    IBridgeRouter public immutable bridgeRouter;

    modifier onlyBridgeRouter() {
        if (msg.sender != address(bridgeRouter)) revert InvalidBridgeRouter(msg.sender);
        _;
    }

    constructor(
        address admin,
        IRouterClient ccipRouter_,
        IBridgeRouter bridgeRouter_
    ) AccessControlDefaultAdminRules(1 days, admin) CCIPReceiver(address(ccipRouter_)) {
        ccipRouter = ccipRouter_;
        bridgeRouter = bridgeRouter_;
        _grantRole(MANAGER_ROLE, admin);
    }

    function getSendFee(Messages.MessageToSend calldata message) external view override returns (uint256 fee) {
        // get chain adapter if available
        (uint64 ccipChainId, bytes32 adapterAddress) = getChainAdapter(message.destinationChainId);

        // get cost of message to be sent
        Client.EVM2AnyMessage memory ccipMessage = _buildCCIPMessage(adapterAddress, message);
        fee = ccipRouter.getFee(ccipChainId, ccipMessage);
    }

    function addChain(
        uint16 townSqChainId,
        uint64 _ccipChainId,
        bytes32 _adapterAddress
    ) external onlyRole(MANAGER_ROLE) {
        // check if chain is already added
        bool isAvailable = isChainAvailable(townSqChainId);
        if (isAvailable) revert ChainAlreadyAdded(townSqChainId);

        // add chain
        townSqChainIdToCCIPAdapter[townSqChainId] = CCIPAdapterParams({
            isAvailable: true,
            ccipChainId: _ccipChainId,
            adapterAddress: _adapterAddress
        });
        ccipChainIdTotownSqChainId[_ccipChainId] = townSqChainId;
    }

    function removeChain(uint16 townSqChainId) external onlyRole(MANAGER_ROLE) {
        // get chain adapter if available
        (uint64 ccipChainId, ) = getChainAdapter(townSqChainId);

        // remove chain
        delete townSqChainIdToCCIPAdapter[townSqChainId];
        delete ccipChainIdTotownSqChainId[ccipChainId];
    }

    function isChainAvailable(uint16 chainId) public view override returns (bool) {
        return townSqChainIdToCCIPAdapter[chainId].isAvailable;
    }

    function getChainAdapter(uint16 chainId) public view returns (uint64 ccipChainId, bytes32 adapterAddress) {
        CCIPAdapterParams memory chainAdapter = townSqChainIdToCCIPAdapter[chainId];
        if (!chainAdapter.isAvailable) revert ChainUnavailable(chainId);

        ccipChainId = chainAdapter.ccipChainId;
        adapterAddress = chainAdapter.adapterAddress;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public pure override(CCIPReceiver, AccessControlDefaultAdminRules) returns (bool) {
        return
            interfaceId == type(AccessControlDefaultAdminRules).interfaceId ||
            CCIPReceiver.supportsInterface(interfaceId);
    }

    function _buildCCIPMessage(
        bytes32 adapterAddress,
        Messages.MessageToSend calldata message
    ) internal pure virtual returns (Client.EVM2AnyMessage memory);
}
