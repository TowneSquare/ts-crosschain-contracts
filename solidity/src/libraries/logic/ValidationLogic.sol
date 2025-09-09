// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {HubStorage} from "../../../src/contracts/lendingHub/HubStorage.sol";
import {HubSpokeStructs} from "../../../src/contracts/HubSpokeStructs.sol";
import {InterestLogic} from "./InterestLogic.sol";
import {IAssetRegistry} from "../../interfaces/IAssetRegistry.sol";
import {IHubPriceUtilities} from "../../interfaces/IHubPriceUtilities.sol";
import {ILiquidationCalculator} from "../../interfaces/ILiquidationCalculator.sol";

library ValidationLogic {
    using InterestLogic for HubSpokeStructs.HubState;

    error ArrayLengthsDoNotMatch();
    error DepositLimitExceeded();
    error DuplicateAddresses();
    error GlobalInsufficientAssets();
    error OnlyMaxLiquidationBonus();
    error OverLiquidated();
    error UnregisteredAsset();
    error VaultCantBeZero();
    error VaultInsufficientAssets();
    error VaultInsufficientBorrows();
    error VaultNotUnderwater();
    error VaultUndercollateralized();

    struct LiquidationParametersInternalTracker {
        uint256 trueNotionalRepaid;
        uint256 colatNotionalRepaid;
        uint256 colatNotionalReceived;
        uint256[] notionalReceivedArray;
        uint256[] maxLiquidationBonusArray;
    }


    function checkVaultHasAssets(address _vaultOwner, bytes32 _asset, uint256 _amount)
        public
        view
    {
        HubSpokeStructs.DenormalizedVaultAmount memory amountsWithInterest = InterestLogic.getVaultAmounts(_vaultOwner, _asset);
        if (amountsWithInterest.deposited < _amount) {
            revert VaultInsufficientAssets();
        }
    }

    /**
     * @dev Checks if the protocol globally has an amount of asset greater than or equal to withdrawn or borrowed amount
     * This check protects protocol reserves, because it requires:
     * 1. denormalizedDeposited >= denormalizedBorrowed + amount
     * 2. baseDeposited + depositInterest >= baseBorrowed + borrowInterest + amount
     * 3. baseDeposited + depositInterest - baseBorrowed - borrowInterest >= amount
     * 4. baseDeposited - baseBorrowed + depositInterest - borrowInterest >= amount
     * 5. baseDeposited - baseBorrowed + depositInterest - borrowInterest >= amount
     * 6. baseDeposited - baseBorrowed - (borrowInterest - depositInterest) >= amount
     * 7. baseDeposited - baseBorrowed - reserve >= amount
     *
     * @param _asset - the ID of the relevant asset
     * @param _amount - the denormalized amount of asset that is to be withdrawn or borrowed
     * @param _checkBorrowLimit - Whether to check the borrow limit being crossed
     */
    function checkProtocolGloballyHasAssets(
        bytes32 _asset,
        uint256 _amount,
        bool _checkBorrowLimit
    ) public view {
        HubSpokeStructs.DenormalizedVaultAmount memory globalAmounts = InterestLogic.getGlobalAmounts(_asset);
        bool globalHasAssets = globalAmounts.deposited >= globalAmounts.borrowed + _amount;
        // only check borrow limit if there are enough assets globally
        if (globalHasAssets && _checkBorrowLimit) {
            IAssetRegistry.AssetInfo memory assetInfo = HubStorage.getAuxilaryContracts().assetRegistry.getAssetInfo(_asset);
            globalHasAssets = assetInfo.borrowLimit >= globalAmounts.borrowed + _amount;
        }

        if (!globalHasAssets) {
            revert GlobalInsufficientAssets();
        }
    }

    /**
     * @dev Check if a deposit of a certain amount of a certain asset is allowed
     *
     * @param _assetId - The ID of the relevant asset
     * @param _assetAmount - The amount of the relevant asset
     * Only returns if this deposit does not exceed the deposit limit for the asset
     */
    function checkAllowedToDeposit(
        bytes32 _assetId,
        uint256 _assetAmount
    )
        public
        view
    {
        IAssetRegistry.AssetInfo memory assetInfo = HubStorage.getAuxilaryContracts().assetRegistry.getAssetInfo(_assetId);
        if (assetInfo.supplyLimit < type(uint256).max) {
            HubSpokeStructs.DenormalizedVaultAmount memory globalAmounts = InterestLogic.getGlobalAmounts(_assetId);

            if (globalAmounts.deposited + _assetAmount > assetInfo.supplyLimit) {
                revert DepositLimitExceeded();
            }
        }
    }

    /**
     * @dev Check if vaultOwner is allowed to withdraw assetAmount of assetAddress from their vault
     *
     * @param _vaultOwner - The address of the owner of the vault
     * @param _assetId - The ID of the relevant asset
     * @param _assetAmount - The amount of the relevant asset
     * Only returns if this withdrawal keeps the vault at a nonnegative notional value (worth >= $0 according to Pyth prices)
     * (where the deposit values are divided by the deposit collateralization ratio and the borrow values are multiplied by the borrow collateralization ratio)
     * and also if there is enough asset in the vault to complete the withdrawal
     * and also if there is enough asset in the total reserve of the protocol to complete the withdrawal
     */
    function checkAllowedToWithdraw(
        address _vaultOwner,
        bytes32 _assetId,
        uint256 _assetAmount
    )
        public
        view
    {
        checkVaultHasAssets(_vaultOwner, _assetId, _assetAmount);
        checkProtocolGloballyHasAssets(_assetId, _assetAmount, false);

        IHubPriceUtilities priceUtilities = HubStorage.getAuxilaryContracts().priceUtilities;
        HubSpokeStructs.NotionalVaultAmount memory effectiveValue = priceUtilities.calculateEffectiveNotionals(
            _assetId,
            HubSpokeStructs.DenormalizedVaultAmount(_assetAmount, 0)
        );
        HubSpokeStructs.NotionalVaultAmount memory notionals = priceUtilities.getVaultEffectiveNotionals(_vaultOwner, true);

        bool overCollat = notionals.deposited >= notionals.borrowed + effectiveValue.deposited;

        if (!overCollat) {
            revert VaultUndercollateralized();
        }
    }

    /**
     * @dev Check if vaultOwner is allowed to borrow assetAmount of assetAddress from their vault
     *
     * @param _vaultOwner - The address of the owner of the vault
     * @param _assetId - The ID of the relevant asset
     * @param _assetAmount - The amount of the relevant asset
     * Only returns (otherwise reverts) if this borrow keeps the vault at a nonnegative notional value (worth >= $0 according to Pyth prices)
     * (where the deposit values are divided by the deposit collateralization ratio and the borrow values are multiplied by the borrow collateralization ratio)
     * and also if there is enough asset in the total reserve of the protocol to complete the borrow
     */
    function checkAllowedToBorrow(
        address _vaultOwner,
        bytes32 _assetId,
        uint256 _assetAmount
    )
        public
        view
    {
        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();
        HubSpokeStructs.NotionalVaultAmount memory notionals = auxContracts.priceUtilities.getVaultEffectiveNotionals(_vaultOwner, true);

        checkProtocolGloballyHasAssets(_assetId, _assetAmount, true);


        HubSpokeStructs.NotionalVaultAmount memory effectiveValue = auxContracts.priceUtilities.calculateEffectiveNotionals(
            _assetId,
            HubSpokeStructs.DenormalizedVaultAmount(0, _assetAmount)
        );
        bool overCollat = notionals.deposited >= notionals.borrowed + effectiveValue.borrowed;

        if (!overCollat) {
            revert VaultUndercollateralized();
        }
    }

    /**
     * @dev Check if vaultOwner is allowed to repay assetAmount of assetAddress to their vault;
     * they must have outstanding borrows of at least assetAmount for assetAddress to enable repayment
     * @param _vaultOwner - The address of the owner of the vault
     * @param _assetId - The ID of the relevant asset
     * @param _assetAmount - The amount of the relevant asset
     */
    function checkAllowedToRepay(
        address _vaultOwner,
        bytes32 _assetId,
        uint256 _assetAmount
    )
        public
        view
    {
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount = InterestLogic.getVaultAmounts(_vaultOwner, _assetId);

        if (vaultAmount.borrowed < _assetAmount) {
            checkAllowedToDeposit(_assetId, _assetAmount - vaultAmount.borrowed);
        }
    }

    /**
     * @notice Checks if the inputs for a liquidation are valid.
     * Specifically, checks if each address is a registered asset and both address arrays do not contain duplicate
     * addresses. All the checks in this function should throw an error.
     *
     * @param _input - The liquidation input, which includes the vault and the assets involved in the liquidation.
     */
    function checkLiquidationInputsValid(
        ILiquidationCalculator.LiquidationInput calldata _input
    ) public view {
        if (_input.vault == address(0)) {
            revert VaultCantBeZero();
        }

        for (uint256 i = 0; i < _input.assets.length;) {
            bytes32 assetId = _input.assets[i].assetId;
            if (!HubStorage.getAuxilaryContracts().assetRegistry.getAssetInfo(assetId).exists) {
                revert UnregisteredAsset();
            }

            for (uint256 j = 0; j < i;) {
                if (assetId == _input.assets[j].assetId) {
                    revert DuplicateAddresses();
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                i++;
            }
        }
    }

    function checkRepaidAsset(
        address _vault,
        ILiquidationCalculator.DenormalizedLiquidationAsset memory _asset
    ) public view returns (uint256 trueValue, uint256 notionalValue) {
        IHubPriceUtilities priceUtilities = HubStorage.getAuxilaryContracts().priceUtilities;
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount = InterestLogic.getVaultAmounts(_vault, _asset.assetId);
        if (vaultAmount.borrowed < _asset.repaidAmount) {
            revert VaultInsufficientBorrows();
        }
        trueValue = priceUtilities.calculateNotionals(_asset.assetId, HubSpokeStructs.DenormalizedVaultAmount(0, _asset.repaidAmount)).borrowed;
        notionalValue = priceUtilities.applyCollateralizationRatios(_asset.assetId, HubSpokeStructs.NotionalVaultAmount(0, trueValue)).borrowed;
    }

    function checkReceivedAsset(
        address _vault,
        ILiquidationCalculator.DenormalizedLiquidationAsset memory _asset
    ) public view returns (uint256 trueValue, uint256 notionalValue) {
        checkVaultHasAssets(_vault, _asset.assetId, _asset.receivedAmount);
        if (_asset.paymentMethod == ILiquidationCalculator.PaymentMethod.TOKEN_TRANSFER) {
            // checking if the amount of asset in the protocol post repayment is greater than the value the liquidator wants to receive
            // the formula is (deposits - borrows) + repayment >= received
            // it's rearranged to avoid underflows
            // this is a variation of HubChecks::checkProtocolGloballyHasAssets that takes into account the amount being repaid
            HubSpokeStructs.DenormalizedVaultAmount memory globalAmounts = InterestLogic.getGlobalAmounts(_asset.assetId);
            if (globalAmounts.deposited + _asset.repaidAmount < _asset.receivedAmount + globalAmounts.borrowed) {
                revert GlobalInsufficientAssets();
            }
        }

        IHubPriceUtilities priceUtilities = HubStorage.getAuxilaryContracts().priceUtilities;
        trueValue = priceUtilities.calculateNotionals(_asset.assetId, HubSpokeStructs.DenormalizedVaultAmount(_asset.receivedAmount, 0)).deposited;
        notionalValue = priceUtilities.applyCollateralizationRatios(_asset.assetId, HubSpokeStructs.NotionalVaultAmount(trueValue, 0)).deposited;
    }

    /**
     * @notice Checks if a liquidation is allowed.
     *
     * This function checks if the vault is underwater (borrowed value > deposited value). If it is not, the function reverts.
     * It then calculates the notional repaid and received amounts for each asset in the liquidation input.
     * Finally, it checks if the liquidation portion is valid.
     *
     * @param _input - The liquidation input, which includes the vault and the assets involved in the liquidation. Input amounts should be normalized
     */
    function checkAllowedToLiquidate(
        ILiquidationCalculator.LiquidationInput calldata _input
    ) public view {
        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();
        HubSpokeStructs.NotionalVaultAmount memory notionals = auxContracts.priceUtilities.getVaultEffectiveNotionals(_input.vault, true);

        if (notionals.deposited >= notionals.borrowed) revert VaultNotUnderwater();

        LiquidationParametersInternalTracker memory params;
        params.notionalReceivedArray = new uint256[](_input.assets.length);
        params.maxLiquidationBonusArray = new uint256[](_input.assets.length);
        for (uint256 i = 0; i < _input.assets.length;) {
            IAssetRegistry.AssetInfo memory info = auxContracts.assetRegistry.getAssetInfo(_input.assets[i].assetId);
            if (_input.assets[i].repaidAmount > 0) {
                (uint256 _trueNotionalRepaid, uint256 _colatNotionalRepaid) = checkRepaidAsset(
                    _input.vault,
                    _input.assets[i]
                );
                params.trueNotionalRepaid += _trueNotionalRepaid;
                params.colatNotionalRepaid += _colatNotionalRepaid;
            }

            if (_input.assets[i].receivedAmount > 0) {
                (uint256 _trueNotionalReceived, uint256 _colatNotionalReceived) = checkReceivedAsset(_input.vault, _input.assets[i]);
                params.notionalReceivedArray[i] = _trueNotionalReceived;
                params.colatNotionalReceived += _colatNotionalReceived;
                params.maxLiquidationBonusArray[i] = info.maxLiquidationBonus;
            }

            unchecked {
                i++;
            }
        }

        checkLiquidationBonusValidity(params.notionalReceivedArray, params.maxLiquidationBonusArray, params.trueNotionalRepaid);
        (uint256 maxHealthFactor, uint256 maxHealthFactorPrecision) = auxContracts.liquidationCalculator.getMaxHealthFactor();
        if (
            ((notionals.deposited - params.colatNotionalReceived) * maxHealthFactorPrecision)
                / (notionals.borrowed - params.colatNotionalRepaid) > maxHealthFactor
        ) {
            revert OverLiquidated();
        }
    }

    /**
     * @dev Checks the validity of the liquidation bonus params. It then calculates the total limit used for all assets involved in the liquidation.
     * If the notional received for an asset is greater than the limit for that asset, or if the total limit used is greater than 1, it reverts.
     * @param _notionalReceived - An array of the notional amounts received for each asset involved in the liquidation.
     * @param _maxLiquidationBonus - An array of the maximum liquidation bonuses for each asset involved in the liquidation.
     * @param _notionalRepaid - The total notional amount repaid in the liquidation.
     */
    function checkLiquidationBonusValidity(
        uint256[] memory _notionalReceived,
        uint256[] memory _maxLiquidationBonus,
        uint256 _notionalRepaid
    ) public view {
        if (_notionalReceived.length != _maxLiquidationBonus.length) revert ArrayLengthsDoNotMatch();

        IAssetRegistry assetRegistry = HubStorage.getAuxilaryContracts().assetRegistry;

        uint256 totalLimitUsed = 0;
        uint256 precision = assetRegistry.COLLATERALIZATION_RATIO_PRECISION();
        uint256 liquidationBonusPrecision = assetRegistry.LIQUIDATION_BONUS_PRECISION();
        for (uint256 i = 0; i < _notionalReceived.length; i++) {
            if (_notionalReceived[i] == 0) {
                continue;
            }
            uint256 limitForThisAsset = _notionalRepaid * _maxLiquidationBonus[i] / liquidationBonusPrecision;
            if (_notionalReceived[i] > limitForThisAsset) revert OnlyMaxLiquidationBonus();

            uint256 limitUsedForThisAsset = precision * _notionalReceived[i] / limitForThisAsset;
            totalLimitUsed += limitUsedForThisAsset;

            if (totalLimitUsed > precision) revert OnlyMaxLiquidationBonus();
        }
    }
}