// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.19;

import {IWormhole} from "@wormhole-relayer/contracts/interfaces/IWormhole.sol";
import {toWormholeFormat, min, pay} from "@wormhole-relayer/contracts/relayer/libraries/Utils.sol";
import {ReentrantDelivery, VaaKey, MsgValueNotEnoughForDeliveryCosts, IWormholeRelayerBase, RelayerPaymentTooSmall} from "../../../interfaces/relayer/IWormholeRelayerTyped.sol";
import {DeliveryInstruction} from "../../relayer/libraries/RelayerInternalStructs.sol";
import {WormholeRelayerStorage} from "./WormholeRelayerStorage.sol";
import "@wormhole-relayer/contracts/interfaces/relayer/TypedUnits.sol";
import {ITownsqPriceOracle} from "../../../interfaces/ITownsqPriceOracle.sol";

abstract contract WormholeRelayerBase is IWormholeRelayerBase {
    using WeiLib for Wei;
    using GasLib for Gas;
    using WeiPriceLib for WeiPrice;
    using GasPriceLib for GasPrice;
    using LocalNativeLib for LocalNative;

    //see https://book.wormhole.com/wormhole/3_coreLayerContracts.html#consistency-levels
    //  15 is valid choice for now but ultimately we want something more canonical (202?)
    //  Also, these values should definitely not be defined here but should be provided by IWormhole!
    uint8 internal constant CONSISTENCY_LEVEL_FINALIZED = 15;
    uint8 internal constant CONSISTENCY_LEVEL_INSTANT = 200;
    uint16 internal constant CHAIN_ID_SOLANA = 1;
    uint16 internal constant CHAIN_ID_ARBITRUM = 23;
    uint256 internal constant SOL_DECIMALS = 1e9;
    uint256 internal constant WETH_DECIMALS = 1e18;

    IWormhole private immutable wormhole;
    uint16 private immutable chainId;
    ITownsqPriceOracle internal immutable priceOracle;
    bytes32 internal immutable solAssetId;
    bytes32 internal immutable wethAssetId;

    modifier nonReentrant() {
        // Reentrancy guard
        WormholeRelayerStorage.ReentrancyGuardState
            storage reentrancyState = WormholeRelayerStorage
                .getReentrancyGuardState();
        if (reentrancyState.lockedBy != address(0)) {
            revert ReentrantDelivery(msg.sender, reentrancyState.lockedBy);
        }
        reentrancyState.lockedBy = msg.sender;

        _;

        reentrancyState.lockedBy = address(0);
    }

    constructor(
        address _wormhole,
        address _priceOracle,
        bytes32 _solAssetId,
        bytes32 _wethAssetId
    ) {
        wormhole = IWormhole(_wormhole);
        chainId = uint16(wormhole.chainId());
        priceOracle = ITownsqPriceOracle(_priceOracle);
        solAssetId = _solAssetId;
        wethAssetId = _wethAssetId;
    }

    function getRegisteredWormholeRelayerContract(
        uint16 _chainId
    ) public view returns (bytes32) {
        return
            WormholeRelayerStorage
                .getRegisteredWormholeRelayersState()
                .registeredWormholeRelayers[_chainId];
    }

    function deliveryAttempted(
        bytes32 deliveryHash
    ) public view returns (bool attempted) {
        return
            WormholeRelayerStorage
                .getDeliverySuccessState()
                .deliverySuccessBlock[deliveryHash] !=
            0 ||
            WormholeRelayerStorage
                .getDeliveryFailureState()
                .deliveryFailureBlock[deliveryHash] !=
            0;
    }

    function deliverySuccessBlock(
        bytes32 deliveryHash
    ) public view returns (uint256 blockNumber) {
        return
            WormholeRelayerStorage
                .getDeliverySuccessState()
                .deliverySuccessBlock[deliveryHash];
    }

    function deliveryFailureBlock(
        bytes32 deliveryHash
    ) public view returns (uint256 blockNumber) {
        return
            WormholeRelayerStorage
                .getDeliveryFailureState()
                .deliveryFailureBlock[deliveryHash];
    }

    //Our get functions require view instead of pure (despite not actually reading storage) because
    //  they can't be evaluated at compile time. (https://ethereum.stackexchange.com/a/120630/103366)

    function getWormhole() public view returns (IWormhole) {
        return wormhole;
    }

    function getChainId() public view returns (uint16) {
        return chainId;
    }

    function getSolAssetId() public view returns (bytes32) {
        return solAssetId;
    }

    function getWethAssetId() public view returns (bytes32) {
        return wethAssetId;
    }

    function getWormholeMessageFee() public view returns (LocalNative) {
        return LocalNative.wrap(getWormhole().messageFee());
    }

    function msgValue() internal view returns (LocalNative) {
        return LocalNative.wrap(msg.value);
    }

    /**
     * Native token send in msg.value must cover delivery gas cost to target chain plus
     * administrative payments on source chain :
     *  - wormholeFee (for publishing DeliveryInstruction VAA)
     *  - relayerFee (this relayer fee)
     */
    function checkMsgValue(
        LocalNative wormholeMessageFee,
        LocalNative relayerReward,
        LocalNative solanaDeliveryPrice
    ) internal view {
        if (
            msgValue() <
            solanaDeliveryPrice + wormholeMessageFee + relayerReward
        ) {
            revert MsgValueNotEnoughForDeliveryCosts(
                msgValue(),
                solanaDeliveryPrice + wormholeMessageFee + relayerReward
            );
        }
    }

    function publishAndPay(
        LocalNative wormholeMessageFee,
        LocalNative relayerReward,
        LocalNative solanaDeliveryPrice,
        bytes memory encodedInstruction,
        uint8 consistencyLevel,
        address payable relayerVault
    ) internal returns (uint64 sequence, bool paymentSucceeded) {
        sequence = getWormhole().publishMessage{
            value: wormholeMessageFee.unwrap()
        }(0, encodedInstruction, consistencyLevel);

        // NOTE:  one wormholeMessageFee was already taken by WormholeTunnel to send token_bridge transfer VAA
        LocalNative relayerPaymentForSolanaDelivery = LocalNative.wrap(
            msg.value
        ) -
            relayerReward -
            wormholeMessageFee;

        // we accept if it is equal or bigger - just in case there is some extra wei added by user to msg.value
        if (relayerPaymentForSolanaDelivery < solanaDeliveryPrice) {
            revert RelayerPaymentTooSmall(
                solanaDeliveryPrice,
                relayerPaymentForSolanaDelivery
            );
        }

        // NOTE: relayer relayerReward stays in relayer contract (this)
        paymentSucceeded = pay(relayerVault, relayerPaymentForSolanaDelivery);

        emit SendEvent(sequence, relayerPaymentForSolanaDelivery);
    }
}
