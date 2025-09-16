// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/ILiquidationCalculator.sol";
import "../../interfaces/IHubPriceUtilities.sol";
import "../../interfaces/IAssetRegistry.sol";
import "../../interfaces/IHub.sol";

contract LiquidationCalculator is ILiquidationCalculator, Ownable {
    IHub hub;

    // internal storage

    // defines the maximum post-liquidation health factor
    // e.g. let:
    // s_deposit = sum of all deposit notional values
    // s_borrow = sum of all borrow notional values
    // l_repay = sum of all repaid notional values
    // l_receive = sum of all received notional values
    // maxHealthFactor = 105%
    // then the post liquidation deposit to borrow ratio can't exceed 105%
    // (s_deposit - l_receive) / (s_borrow - l_repay) <= maxHealthFactor
    // this is to prevent over-liquidation
    uint256 maxHealthFactor;
    uint256 maxHealthFactorPrecision;

    // errors
    error VaultCantBeZero();
    error UnregisteredAsset();
    error DuplicateAddresses();
    error ArrayLengthsDoNotMatch();
    error VaultNotUnderwater();
    error OnlyMaxLiquidationBonus();
    error OverLiquidated();
    error GlobalInsufficientAssets();

    constructor(address _hub, uint256 _maxHealthFactor, uint256 _maxHealthFactorPrecision) Ownable(msg.sender) {
        hub = IHub(_hub);
        setMaxHealthFactor(_maxHealthFactor, _maxHealthFactorPrecision);
    }

    function getPriceUtilities() internal view returns (IHubPriceUtilities) {
        return IHubPriceUtilities(hub.getPriceUtilities());
    }

    function getAssetRegistry() internal view returns (IAssetRegistry) {
        return IAssetRegistry(hub.getAssetRegistry());
    }

    function getAssetInfo(bytes32 asset) internal view returns (IAssetRegistry.AssetInfo memory) {
        return getAssetRegistry().getAssetInfo(asset);
    }

    function getMaxHealthFactor() external view override returns (uint256, uint256) {
        return (maxHealthFactor, maxHealthFactorPrecision);
    }

    // OWNER FUNCTIONS

    /**
     * @notice Sets the maximum health factor and its precision.
     * @dev Can only be called by the contract owner.
     * @param _maxHealthFactor The maximum health factor to be set.
     * @param _maxHealthFactorPrecision The precision of the maximum health factor.
     */
    function setMaxHealthFactor(uint256 _maxHealthFactor, uint256 _maxHealthFactorPrecision) public onlyOwner {
        maxHealthFactor = _maxHealthFactor;
        maxHealthFactorPrecision = _maxHealthFactorPrecision;
    }
}
