// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "./IHub.sol";
import "./IAssetRegistry.sol";
import "./ITownsqPriceOracle.sol";
import "../contracts/HubSpokeStructs.sol";

interface IHubPriceUtilities {
    function getAssetRegistry() external view returns (IAssetRegistry);

    function getPrices(
        bytes32 asset
    ) external view returns (uint256, uint256, uint256, uint256);

    function getVaultEffectiveNotionals(
        address vaultOwner,
        bool collateralizationRatios
    ) external view returns (HubSpokeStructs.NotionalVaultAmount memory);

    function calculateNotionals(
        bytes32 asset,
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount
    ) external view returns (HubSpokeStructs.NotionalVaultAmount memory);

    function calculateEffectiveNotionals(
        bytes32 asset,
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount
    ) external view returns (HubSpokeStructs.NotionalVaultAmount memory);

    function invertNotionals(
        bytes32 asset,
        HubSpokeStructs.NotionalVaultAmount memory realValues
    ) external view returns (HubSpokeStructs.DenormalizedVaultAmount memory);

    function applyCollateralizationRatios(
        bytes32 asset,
        HubSpokeStructs.NotionalVaultAmount memory vaultAmount
    ) external view returns (HubSpokeStructs.NotionalVaultAmount memory);

    function removeCollateralizationRatios(
        bytes32 asset,
        HubSpokeStructs.NotionalVaultAmount memory vaultAmount
    ) external view returns (HubSpokeStructs.NotionalVaultAmount memory);

    function getHub() external view returns (IHub);

    function setHub(IHub _hub) external;

    function getPriceOracle() external view returns (ITownsqPriceOracle);

    function setPriceOracle(ITownsqPriceOracle _priceOracle) external;

    function getPriceStandardDeviations()
        external
        view
        returns (uint256, uint256);

    function setPriceStandardDeviations(
        uint256 _priceStandardDeviations,
        uint256 _precision
    ) external;
}
