// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.19;

import "@wormhole-relayer/contracts/interfaces/relayer/TypedUnits.sol";

// -------------------------------------- Persistent Storage ---------------------------------------

library WormholeRelayerStorage {
    struct OwnerState {
        address owner;
    }

    //keccak256("OwnerState") - 1
    bytes32 public constant OWNER_STORAGE_SLOT = 0xe2005ff01f564496e3d5221b0d7d5439d785519e60a4af00ee5695b0460f94b3;

    function getOwnerState() public pure returns (OwnerState storage state) {
        assembly ("memory-safe") {
            state.slot := OWNER_STORAGE_SLOT
        }
    }

    struct GovernanceState {
        // mapping of IWormhole.VM.hash of previously executed governance VMs
        mapping(bytes32 => bool) consumedGovernanceActions;
    }

    //keccak256("GovernanceState") - 1
    bytes32 public constant GOVERNANCE_STORAGE_SLOT = 0x970ad24d4754c92e299cabb86552091f5df0a15abc0f1b71f37d3e30031585dc;

    function getGovernanceState() public pure returns (GovernanceState storage state) {
        assembly ("memory-safe") {
            state.slot := GOVERNANCE_STORAGE_SLOT
        }
    }

    struct RegisteredWormholeRelayersState {
        // chainId => wormhole address mapping of relayer contracts on other chains
        mapping(uint16 => bytes32) registeredWormholeRelayers;
    }

    //keccak256("RegisteredCoreRelayersState") - 1
    bytes32 public constant REGISTERED_CORE_RELAYERS_STORAGE_SLOT = 0x9e4e57806ba004485cfae8ca22fb13380f01c10b1b0ccf48c20464961643cf6d;

    function getRegisteredWormholeRelayersState()
        public
        pure
        returns (RegisteredWormholeRelayersState storage state)
    {
        assembly ("memory-safe") {
            state.slot := REGISTERED_CORE_RELAYERS_STORAGE_SLOT
        }
    }

    // Replay Protection and Indexing

    struct DeliverySuccessState {
        mapping(bytes32 => uint256) deliverySuccessBlock;
    }

    struct DeliveryFailureState {
        mapping(bytes32 => uint256) deliveryFailureBlock;
    }

    //keccak256("DeliverySuccessState") - 1
    bytes32 public constant DELIVERY_SUCCESS_STATE_STORAGE_SLOT = 0x1b988580e74603c035f5a7f71f2ae4647578af97cd0657db620836b9955fd8f5;

    //keccak256("DeliveryFailureState") - 1
    bytes32 public constant DELIVERY_FAILURE_STATE_STORAGE_SLOT = 0x6c615753402911c4de18a758def0565f37c41834d6eff72b16cb37cfb697f2a5;

    function getDeliverySuccessState() public pure returns (DeliverySuccessState storage state) {
        assembly ("memory-safe") {
            state.slot := DELIVERY_SUCCESS_STATE_STORAGE_SLOT
        }
    }

    function getDeliveryFailureState() public pure returns (DeliveryFailureState storage state) {
        assembly ("memory-safe") {
            state.slot := DELIVERY_FAILURE_STATE_STORAGE_SLOT
        }
    }

    struct ReentrancyGuardState {
        // if 0 address, no reentrancy guard is active
        // otherwise, the address of the contract that has locked the reentrancy guard (msg.sender)
        address lockedBy;
    }

    //keccak256("ReentrancyGuardState") - 1
    bytes32 public constant REENTRANCY_GUARD_STORAGE_SLOT = 0x44dc27ebd67a87ad2af1d98fc4a5f971d9492fe12498e4c413ab5a05b7807a67;

    function getReentrancyGuardState() public pure returns (ReentrancyGuardState storage state) {
        assembly ("memory-safe") {
            state.slot := REENTRANCY_GUARD_STORAGE_SLOT
        }
    }

    struct CustomRelayerConfig {
        bytes32 hubAddress;
        bytes32 solanaEmitterAddress;
        address wormholeTunnel;
        uint256 maxGasLimit;
    }

    //keccak256("CustomRelayerConfig") - 1
    bytes32 public constant CUSTOM_RELAYER_CONFIG = 0xac5632886cc7ce290f00bd86af682aaa253fdb20638581a089cf31dc61aebd8c;

    function getCustomRelayerConfig() public pure returns (CustomRelayerConfig storage state) {
        assembly ("memory-safe") {
            state.slot := CUSTOM_RELAYER_CONFIG
        }
    }

    /**
     * @param solanaDeliveryPrice: Total cost of transactions in SOL for delivery on Solana chain
     * @param relayerReward: relayer reward for performing the delivery
     * @param relayerVault: The address where relayer fees should be sent to
     */
    struct RoutingCostConfig {
        uint256 solanaDeliveryPrice;
        uint256 relayerReward;
        address payable relayerVault;
    }

    //keccak256("RoutingCostConfig") - 1
    bytes32 public constant ROUTING_COST_CONFIG = 0x0ef547f873b1c01c60e025eb8a3cee4cc4fb3acf07160dc7c59cbca3ee7e65a2;

    function getRoutingCostConfig() public pure returns (RoutingCostConfig storage state) {
        assembly ("memory-safe") {
            state.slot := ROUTING_COST_CONFIG
        }
    }
}
