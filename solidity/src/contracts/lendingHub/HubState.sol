// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILiquidationCalculator} from "../../interfaces/ILiquidationCalculator.sol";
import {IHubPriceUtilities} from "../../interfaces/IHubPriceUtilities.sol";
import {IAssetRegistry} from "../../interfaces/IAssetRegistry.sol";
import {IWormholeTunnel} from "../../interfaces/IWormholeTunnel.sol";
import {IMoneyMarketRewardsDistributor} from "../../interfaces/rewards/IMoneyMarketRewardsDistributor.sol";
import {HubSpokeStructs} from "../HubSpokeStructs.sol";
import {HubSpokeEvents} from "../HubSpokeEvents.sol";
import {HubStorage} from "./HubStorage.sol";

/**
 * @title HubState
 * @notice Contract holding state variable for the Hub contract
 */
abstract contract HubState is OwnableUpgradeable, HubSpokeEvents {

    error InvalidPrecision();

    HubSpokeStructs.HubState _deprecated_state;

    function getAssetInfo(bytes32 assetId) internal view virtual returns (IAssetRegistry.AssetInfo memory) {
        return getAssetRegistry().getAssetInfo(assetId);
    }

    function getLiquidationCalculator() public view returns (ILiquidationCalculator) {
        return HubStorage.getAuxilaryContracts().liquidationCalculator;
    }

    function getPriceUtilities() public view returns (IHubPriceUtilities) {
        return HubStorage.getAuxilaryContracts().priceUtilities;
    }

    function getAssetRegistry() public view returns (IAssetRegistry) {
        return HubStorage.getAuxilaryContracts().assetRegistry;
    }

    function getWormholeTunnel() public view returns (IWormholeTunnel) {
        return HubStorage.getAuxilaryContracts().wormholeTunnel;
    }

    function getRewardDistributor() public view returns (IMoneyMarketRewardsDistributor) {
        return HubStorage.getAuxilaryContracts().rewardDistributor;
    }

    function getLiquidationFeeAndPrecision() public view returns (uint256, uint256) {
        HubSpokeStructs.FeesLimitsAndPrecisionsState storage state = HubStorage.getFeesLimitsAndPrecisionsState();
        return (state.liquidationFee, state.liquidationFeePrecision);
    }

    function getLastActivityBlockTimestamp(bytes32 _assetId) public view returns (uint256) {
        return HubStorage.getAssetState(_assetId).lastActivityBlockTimestamp;
    }

    function getInterestAccrualIndices(bytes32 _assetId) public view returns (HubSpokeStructs.AccrualIndices memory) {
        HubSpokeStructs.AccrualIndices memory indices = HubStorage.getAssetState(_assetId).indices;
        if (indices.deposited == 0 || indices.borrowed == 0) {
            // seed with precision if not set
            uint256 precision = getInterestAccrualIndexPrecision();
            return HubSpokeStructs.AccrualIndices({deposited: precision, borrowed: precision});
        }

        return indices;
    }

    function getInterestAccrualIndexPrecision() public view returns (uint256) {
        return HubStorage.getFeesLimitsAndPrecisionsState().interestAccrualIndexPrecision;
    }

    /**
     * @notice Sets the default gas limit used for wormhole relay quotes
     * @param value: The new value for `defaultGasLimit`
     */
    function setDefaultGasLimit(uint256 value) public onlyOwner {
        HubSpokeStructs.FeesLimitsAndPrecisionsState storage state = HubStorage.getFeesLimitsAndPrecisionsState();
        state.defaultGasLimit = value;
    }

    /**
     * @dev Sets the gas limit used for refunding of returnCost amount
     * @param value: The new value for `refundGasLimit`
     */
    function setRefundGasLimit(uint256 value) public onlyOwner {
        HubSpokeStructs.FeesLimitsAndPrecisionsState storage state = HubStorage.getFeesLimitsAndPrecisionsState();
        state.refundGasLimit = value;
    }

    /**
     * @notice Updates the liquidation fee
     * @param _liquidationFee: The new liquidation fee
     */
    function setLiquidationFee(uint256 _liquidationFee, uint256 _precision) public onlyOwner {
        if (_liquidationFee > _precision) {
            revert InvalidPrecision();
        }
        HubSpokeStructs.FeesLimitsAndPrecisionsState storage state = HubStorage.getFeesLimitsAndPrecisionsState();
        state.liquidationFee = _liquidationFee;
        state.liquidationFeePrecision = _precision;
        emit SetLiquidationFee(_liquidationFee, _precision);
    }

    /**
     * @notice Sets the liquidation calculator
     * @param _calculator: The address of the liquidation calculator
     */
    function setLiquidationCalculator(address _calculator) external onlyOwner {
        HubSpokeStructs.AuxilaryContracts storage state = HubStorage.getAuxilaryContracts();
        state.liquidationCalculator = ILiquidationCalculator(_calculator);
    }

    function setPriceUtilities(address _priceUtilities) external onlyOwner {
        HubSpokeStructs.AuxilaryContracts storage state = HubStorage.getAuxilaryContracts();
        state.priceUtilities = IHubPriceUtilities(_priceUtilities);
    }

    function setAssetRegistry(address _assetRegistry) public onlyOwner {
        HubSpokeStructs.AuxilaryContracts storage state = HubStorage.getAuxilaryContracts();
        state.assetRegistry = IAssetRegistry(_assetRegistry);
    }

    function getSpokeBalances(
        uint16 chainId,
        bytes32 tokenHomeAddress
    ) public view returns (HubSpokeStructs.HubSpokeBalances memory) {
        return HubStorage.getSpokeState(chainId).balances[tokenHomeAddress];
    }

    function setWormholeTunnel(address _wormholeTunnel) public onlyOwner {
        HubSpokeStructs.AuxilaryContracts storage state = HubStorage.getAuxilaryContracts();
        state.wormholeTunnel = IWormholeTunnel(_wormholeTunnel);
    }

    function setRewardDistributor(address _distributor) external onlyOwner {
        HubSpokeStructs.AuxilaryContracts storage state = HubStorage.getAuxilaryContracts();
        state.rewardDistributor = IMoneyMarketRewardsDistributor(_distributor);
    }
}
