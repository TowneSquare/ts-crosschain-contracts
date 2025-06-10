// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.19;

// import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Upgrade.sol";
import "@openzeppelin/contracts-upgradeable-4.7.3/proxy/ERC1967/ERC1967UpgradeUpgradeable.sol";

import {IWormhole} from "@wormhole-relayer/contracts/interfaces/IWormhole.sol";
import {InvalidPayloadLength} from "../../../interfaces/relayer/IWormholeRelayerTyped.sol";
import {fromWormholeFormat} from "@wormhole-relayer/contracts/relayer/libraries/Utils.sol";
import {BytesParsing} from "@wormhole-relayer/contracts/relayer/libraries/BytesParsing.sol";
import {
    WormholeRelayerStorage
} from "./WormholeRelayerStorage.sol";
import {WormholeRelayerBase} from "./WormholeRelayerBase.sol";

error GovernanceActionAlreadyConsumed(bytes32 hash);
error InvalidGovernanceVM(string reason);
error InvalidGovernanceChainId(uint16 parsed, uint16 expected);
error InvalidGovernanceContract(bytes32 parsed, bytes32 expected);

error InvalidPayloadChainId(uint16 parsed, uint16 expected);
error InvalidPayloadAction(uint8 parsed, uint8 expected);
error InvalidPayloadModule(bytes32 parsed, bytes32 expected);
error InvalidFork();
error ContractUpgradeFailed(bytes failure);
error ChainAlreadyRegistered(uint16 chainId, bytes32 registeredWormholeRelayerContract);


abstract contract WormholeRelayerGovernance is WormholeRelayerBase, ERC1967UpgradeUpgradeable {
    //Right shifted ascii encoding of "WormholeRelayer"
    bytes32 private constant module = 0x0000000000000000000000000000000000576f726d686f6c6552656c61796572;

    event ContractUpgraded(address indexed oldContract, address indexed newContract);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error UnauthorizedAccount(address account);
    error InvalidOwner(address owner);

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function owner() public view returns (address) {
        return WormholeRelayerStorage.getOwnerState().owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) {
            revert InvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    function _checkOwner() internal view {
        if (owner() != msg.sender) {
            revert UnauthorizedAccount(msg.sender);
        }
    }

    function _transferOwnership(address newOwner) internal {
        WormholeRelayerStorage.OwnerState storage ownerState = WormholeRelayerStorage.getOwnerState();
        address oldOwner = ownerState.owner;
        ownerState.owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    //By checking that only the contract can call itself, we can enforce that the migration code is
    //  executed upon program upgrade and that it can't be called externally by anyone else.
    function checkAndExecuteUpgradeMigration() external {
        assert(msg.sender == address(this));
        executeUpgradeMigration();
    }

    function executeUpgradeMigration() internal virtual {
        //override and implement in WormholeRelayer upon contract upgrade (if required)
    }

    /**
     * Register foreign relayer contract address on given chain that this relayer can interact with
     */
    function registerWormholeRelayerContract(uint16 foreignChainId, bytes32 foreignAddress) external onlyOwner {
        WormholeRelayerStorage.RegisteredWormholeRelayersState storage relayersState = WormholeRelayerStorage.getRegisteredWormholeRelayersState();
        if (relayersState.registeredWormholeRelayers[foreignChainId] != bytes32(0)) {
            revert ChainAlreadyRegistered(foreignChainId, relayersState.registeredWormholeRelayers[foreignChainId]);
        }
        relayersState.registeredWormholeRelayers[foreignChainId] = foreignAddress;
    }

    function contractUpgrade(address newImplementation) external onlyOwner {
        address currentImplementation = _getImplementation();

        _upgradeTo(newImplementation);

        (bool success, bytes memory revertData) =
            address(this).call(abi.encodeCall(this.checkAndExecuteUpgradeMigration, ()));

        if (!success) {
            revert ContractUpgradeFailed(revertData);
        }

        emit ContractUpgraded(currentImplementation, newImplementation);
    }

    function setCustomRelayerConfig(WormholeRelayerStorage.CustomRelayerConfig memory config) external onlyOwner {
        WormholeRelayerStorage.CustomRelayerConfig storage storedConfig = WormholeRelayerStorage.getCustomRelayerConfig();
        storedConfig.hubAddress = config.hubAddress;
        storedConfig.solanaEmitterAddress = config.solanaEmitterAddress;
        storedConfig.wormholeTunnel = config.wormholeTunnel;
        storedConfig.maxGasLimit = config.maxGasLimit;
    }

    function getCustomRelayerConfig() external pure returns (WormholeRelayerStorage.CustomRelayerConfig memory) {
        return WormholeRelayerStorage.getCustomRelayerConfig();
    }

    function setRoutingCostConfig(WormholeRelayerStorage.RoutingCostConfig memory config) external onlyOwner {
        WormholeRelayerStorage.RoutingCostConfig storage storedConfig = WormholeRelayerStorage.getRoutingCostConfig();
        storedConfig.solanaDeliveryPrice = config.solanaDeliveryPrice;
        storedConfig.relayerReward = config.relayerReward;
        storedConfig.relayerVault = config.relayerVault;
    }

    function getRoutingCostConfig() external pure returns (WormholeRelayerStorage.RoutingCostConfig memory) {
        return WormholeRelayerStorage.getRoutingCostConfig();
    }

    function withdrawEth() external onlyOwner returns(uint256) {
        uint256 balance = address(this).balance;
        require(balance > 0, "Nothing to withdraw");

        (bool success, ) = owner().call{value: balance}("");
        require(success, "Failed to withdraw ether");

        return balance;
    }

}
