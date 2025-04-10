// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import {ITownsqPriceOracle} from "../../interfaces/ITownsqPriceOracle.sol";
import "../../interfaces/IHub.sol";
import "../../interfaces/IHubPriceUtilities.sol";
import "../HubSpokeStructs.sol";

/**
 * @title HubPriceUtilities
 * @notice Contract defining price-related utility functions for the Hub contract
 */
contract HubPriceUtilities is IHubPriceUtilities, Ownable {
    IHub hub;
    ITownsqPriceOracle priceOracle;

    // the amount of confidence intervals to use for the lower and upper bounds of the price
    uint256 priceStandardDeviations;
    uint256 priceStandardDeviationsPrecision;

    error NoZeroOrNegativePrices();

    constructor(
        address _hub,
        address _priceOracle,
        uint256 _priceStandardDeviations,
        uint256 _priceStandardDeviationsPrecision
    ) Ownable(msg.sender) {
        require(_hub != address(0));
        require(_priceOracle != address(0));
        hub = IHub(_hub);
        priceOracle = ITownsqPriceOracle(_priceOracle);
        priceStandardDeviations = _priceStandardDeviations;
        priceStandardDeviationsPrecision = _priceStandardDeviationsPrecision;
    }

    function getAssetRegistry() public view override returns (IAssetRegistry) {
        return IAssetRegistry(hub.getAssetRegistry());
    }

    function getAssetInfo(
        bytes32 _id
    ) internal view returns (IAssetRegistry.AssetInfo memory) {
        return getAssetRegistry().getAssetInfo(_id);
    }

    /**
     * @dev Gets priceCollateral and priceDebt, which are price - c*stdev and price + c*stdev, respectively
     * where c is a constant specified by the protocol (priceStandardDeviations/priceStandardDeviationPrecision),
     * and stdev is the standard deviation of the price.
     * Multiplies each of these values by getPriceStandardDeviationsPrecision().
     * These values are used as lower and upper bounds of the price when determining whether to allow
     * borrows and withdraws
     *
     * @param assetId the ID of the relevant asset
     * @return truePrice - the price of the asset
     * @return priceCollateral - the price of the asset when used as collateral [true price reduced by c*stdev]
     * @return priceDebt - the price of the asset when used as debt [true price increased by c*stdev]
     * @return pricePrecision - the precision of the price
     */
    function getPrices(
        bytes32 assetId
    )
        public
        view
        override
        returns (
            uint256 truePrice,
            uint256 priceCollateral,
            uint256 priceDebt,
            uint256 pricePrecision
        )
    {
        (
            uint256 price,
            uint256 conf,
            uint256 _pricePrecision
        ) = getOraclePrices(assetId);
        // use conservative (from protocol's perspective) prices for collateral (low) and debt (high)--see https://docs.pyth.network/consume-data/best-practices#confidence-intervals
        uint256 confidenceInterval = (conf * priceStandardDeviations) /
            priceStandardDeviationsPrecision;

        if (price <= confidenceInterval) {
            revert NoZeroOrNegativePrices();
        }

        truePrice = price;
        priceCollateral = price - confidenceInterval;
        priceDebt = price + confidenceInterval;
        pricePrecision = _pricePrecision;
    }

    /**
     * @dev Get the price, through Pyth, of the asset at address assetAddress
     * @param assetId - The ID of the relevant asset
     * @return The price (in USD) of the asset, from Pyth;
     * @return The confidence (in USD) of the asset's price
     */
    function getOraclePrices(
        bytes32 assetId
    ) internal view returns (uint256, uint256, uint256) {
        ITownsqPriceOracle.Price memory oraclePrice = priceOracle.getPrice(
            assetId
        );
        return (
            oraclePrice.price,
            oraclePrice.confidence,
            oraclePrice.precision
        );
    }

    /**
     * @dev Using the pyth prices, get the total price of the assets deposited into the vault, and
     * total price of the assets borrowed from the vault (multiplied by their respecetive collateralization ratios)
     * The result will be multiplied by interestAccrualIndexPrecision * priceStandardDeviationsPrecision * 10^(maxDecimals) * (collateralizationRatioPrecision if collateralizationRatios is true, otherwise 1)
     * because we are denormalizing without dividing by this value, and we are (maybe) multiplying by collateralizationRatios without dividing
     * by the precision, and we are using getPrices which returns the prices multiplied by priceStandardDeviationsPrecision
     * and we are multiplying by 10^maxDecimals to keep integers when we divide by 10^(decimals of each asset).
     *
     * @param vaultOwner - The address of the owner of the vault
     * @param collateralizationRatios - Whether or not to multiply by collateralizationRatios in the computation
     * @return NotionalVaultAmount memory The total value of the assets deposited into and borrowed from the vault
     */
    function getVaultEffectiveNotionals(
        address vaultOwner,
        bool collateralizationRatios
    )
        public
        view
        override
        returns (HubSpokeStructs.NotionalVaultAmount memory)
    {
        HubSpokeStructs.NotionalVaultAmount
            memory totalNotionalValues = HubSpokeStructs.NotionalVaultAmount(
                0,
                0
            );
        bytes32[] memory allowList = getAssetRegistry().getRegisteredAssets();
        for (uint256 i = 0; i < allowList.length; ) {
            bytes32 asset = allowList[i];
            HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount = hub
                .getVaultAmounts(vaultOwner, asset);
            HubSpokeStructs.NotionalVaultAmount
                memory notionalValues = calculateNotionals(asset, vaultAmount);
            if (collateralizationRatios) {
                notionalValues = applyCollateralizationRatios(
                    asset,
                    notionalValues
                );
            }
            totalNotionalValues.deposited += notionalValues.deposited;
            totalNotionalValues.borrowed += notionalValues.borrowed;

            unchecked {
                i++;
            }
        }

        return totalNotionalValues;
    }

    /**
     * @dev Calculates the effective notional values for the assets deposited and borrowed from the vault.
     * The function takes into account the collateralization ratios if specified.
     * The effective notional values are used to determine the total price of the assets in the vault.
     * Precision: 1e36 = protocol precision 1e18 * price precision 1e18
     *
     * @param asset - The address of the asset in the vault
     * @param vaultAmount - The struct with amount deposited and borrowed
     * @return VaultAmount - the notional amount deposited and borrowed
     */
    function calculateNotionals(
        bytes32 asset,
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount
    )
        public
        view
        override
        returns (HubSpokeStructs.NotionalVaultAmount memory)
    {
        IAssetRegistry assetRegistry = getAssetRegistry();
        IAssetRegistry.AssetInfo memory assetInfo = assetRegistry.getAssetInfo(
            asset
        );
        (, uint256 priceCollateral, uint256 priceDebt, ) = getPrices(asset);
        uint256 expVal = 10 **
            (assetRegistry.PROTOCOL_MAX_DECIMALS() - assetInfo.decimals);

        return
            HubSpokeStructs.NotionalVaultAmount(
                vaultAmount.deposited * priceCollateral * expVal,
                vaultAmount.borrowed * priceDebt * expVal
            );
    }

    function invertNotionals(
        bytes32 asset,
        HubSpokeStructs.NotionalVaultAmount memory realValues
    )
        public
        view
        override
        returns (HubSpokeStructs.DenormalizedVaultAmount memory)
    {
        IAssetRegistry assetRegistry = getAssetRegistry();
        IAssetRegistry.AssetInfo memory assetInfo = assetRegistry.getAssetInfo(
            asset
        );
        (, uint256 priceCollateral, uint256 priceDebt, ) = getPrices(asset);
        uint256 expVal = 10 **
            (assetRegistry.PROTOCOL_MAX_DECIMALS() - assetInfo.decimals);

        return
            HubSpokeStructs.DenormalizedVaultAmount(
                realValues.deposited / (priceCollateral * expVal),
                realValues.borrowed / (priceDebt * expVal)
            );
    }

    function applyCollateralizationRatios(
        bytes32 asset,
        HubSpokeStructs.NotionalVaultAmount memory vaultAmount
    )
        public
        view
        override
        returns (HubSpokeStructs.NotionalVaultAmount memory)
    {
        IAssetRegistry assetRegistry = getAssetRegistry();
        IAssetRegistry.AssetInfo memory assetInfo = assetRegistry.getAssetInfo(
            asset
        );
        uint256 collateralizationRatioPrecision = assetRegistry
            .COLLATERALIZATION_RATIO_PRECISION();
        vaultAmount.deposited =
            (vaultAmount.deposited * collateralizationRatioPrecision) /
            assetInfo.collateralizationRatioDeposit;
        vaultAmount.borrowed =
            (vaultAmount.borrowed * assetInfo.collateralizationRatioBorrow) /
            collateralizationRatioPrecision;
        return vaultAmount;
    }

    function removeCollateralizationRatios(
        bytes32 asset,
        HubSpokeStructs.NotionalVaultAmount memory vaultAmount
    )
        public
        view
        override
        returns (HubSpokeStructs.NotionalVaultAmount memory)
    {
        IAssetRegistry assetRegistry = getAssetRegistry();
        IAssetRegistry.AssetInfo memory assetInfo = assetRegistry.getAssetInfo(
            asset
        );
        uint256 collateralizationRatioPrecision = assetRegistry
            .COLLATERALIZATION_RATIO_PRECISION();
        vaultAmount.deposited =
            (vaultAmount.deposited * assetInfo.collateralizationRatioDeposit) /
            collateralizationRatioPrecision;
        vaultAmount.borrowed =
            (vaultAmount.borrowed * collateralizationRatioPrecision) /
            assetInfo.collateralizationRatioBorrow;
        return vaultAmount;
    }

    function calculateEffectiveNotionals(
        bytes32 asset,
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount
    )
        public
        view
        override
        returns (HubSpokeStructs.NotionalVaultAmount memory)
    {
        return
            applyCollateralizationRatios(
                asset,
                calculateNotionals(asset, vaultAmount)
            );
    }

    // Getter for hub
    function getHub() public view override returns (IHub) {
        return hub;
    }

    function setHub(IHub _hub) public override onlyOwner {
        require(address(_hub) != address(0));
        hub = _hub;
    }

    function getPriceOracle()
        public
        view
        override
        returns (ITownsqPriceOracle)
    {
        return priceOracle;
    }

    function setPriceOracle(
        ITownsqPriceOracle _priceOracle
    ) public override onlyOwner {
        require(address(_priceOracle) != address(0));
        priceOracle = _priceOracle;
    }

    function getPriceStandardDeviations()
        public
        view
        override
        returns (uint256, uint256)
    {
        return (priceStandardDeviations, priceStandardDeviationsPrecision);
    }

    function setPriceStandardDeviations(
        uint256 _priceStandardDeviations,
        uint256 _precision
    ) public override onlyOwner {
        priceStandardDeviations = _priceStandardDeviations;
        priceStandardDeviationsPrecision = _precision;
    }
}
