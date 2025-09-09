// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { UD60x18, ud, UNIT } from "@prb/math/src/UD60x18.sol";
import "../../../src/interfaces/IInterestRateCalculator.sol";
import {HubSpokeStructs} from "../../../src/contracts/HubSpokeStructs.sol";
import {HubStorage} from "../../../src/contracts/lendingHub/HubStorage.sol";

library InterestLogic {
    error UnregisteredAsset();

    function expBaseFromRateAndPrecision(uint256 rate, uint256 precision) public pure returns (uint256) {
        uint256 divisor = 365 days;
        return (divisor * precision + rate) / divisor;
    }

    function exponentiate(uint256 base, uint256 secondsElapsed, uint256 precision) public pure returns (uint256) {
        // scale the exponentiationBase to UD60x18 precision
        UD60x18 baseUd = ud(base * UNIT.unwrap() / precision);
        // exponentiation -> unwrap -> scale back to precisionn
        return baseUd.powu(secondsElapsed).unwrap() * precision / UNIT.unwrap();
    }

    function indexOrDefault(bytes32 _assetId) public view returns (HubSpokeStructs.AccrualIndices memory) {
        HubSpokeStructs.AccrualIndices storage indices = HubStorage.getAssetState(_assetId).indices;
        if (indices.deposited == 0 && indices.borrowed == 0) {
            uint256 precision = HubStorage.getFeesLimitsAndPrecisionsState().interestAccrualIndexPrecision;
            return HubSpokeStructs.AccrualIndices({ deposited: precision, borrowed: precision });
        }
        return indices;
    }

    function computeAccrualIndices(
        IInterestRateCalculator.InterestRates memory rates,
        uint256 secondsElapsed,
        uint256 precision
    ) public pure returns (HubSpokeStructs.AccrualIndices memory accrualIndices) {
        uint256 depositExpBase = expBaseFromRateAndPrecision(rates.depositRate, rates.precision);
        uint256 borrowExpBase = expBaseFromRateAndPrecision(rates.borrowRate, rates.precision);
        accrualIndices.deposited = exponentiate(depositExpBase, secondsElapsed, rates.precision) * precision / rates.precision;
        accrualIndices.borrowed = exponentiate(borrowExpBase, secondsElapsed, rates.precision) * precision / rates.precision;
    }

    function getAmountsWithCompoundedInterest(
        HubSpokeStructs.DenormalizedVaultAmount memory amountWithoutInterest,
        IInterestRateCalculator.InterestRates memory rates,
        uint256 secondsElapsed
    ) public pure returns (HubSpokeStructs.DenormalizedVaultAmount memory amountWithInterest) {
        HubSpokeStructs.AccrualIndices memory indices = computeAccrualIndices(rates, secondsElapsed, rates.precision);
        amountWithInterest.deposited = amountWithoutInterest.deposited * indices.deposited / rates.precision;
        amountWithInterest.borrowed = amountWithoutInterest.borrowed * indices.borrowed / rates.precision;
    }

    function getCurrentAccrualIndices(bytes32 assetId) public view returns (HubSpokeStructs.AccrualIndices memory) {
        HubSpokeStructs.AssetState storage assetState = HubStorage.getAssetState(assetId);
        uint256 lastActivity = assetState.lastActivityBlockTimestamp;
        if (lastActivity == block.timestamp) {
            return indexOrDefault(assetId);
        } else {
            IAssetRegistry.AssetInfo memory info = HubStorage.getAuxilaryContracts().assetRegistry.getAssetInfo(assetId);
            if (!info.exists) {
                revert UnregisteredAsset();
            }
            uint256 precision = HubStorage.getFeesLimitsAndPrecisionsState().interestAccrualIndexPrecision;
            return getCurrentAccrualIndices(
                IInterestRateCalculator(info.interestRateCalculator),
                lastActivity,
                assetState.totals,
                indexOrDefault(assetId),
                precision
            );
        }
    }

    /**
     * @dev Calculates the current accrual indices for a given asset.
     * It calculates the seconds elapsed since the last activity, the total assets deposited,
     * and the current interest accrual indices. If seconds elapsed and deposited are not zero,
     * it calculates the total assets borrowed, normalizes the deposited and borrowed amounts,
     * gets the asset info, and computes the interest factor, reserve factor, and reserve precision.
     * It then updates the borrowed and deposited accrual indices accordingly.
     * @param _interestRateCalculator The asset's interest rate calculator
     * @param _lastActivityBlockTimestamp The timestamp of last activity on this asset
     * @param _globalAssetAmounts The totals for deposits and borrows in the Hub
     * @param _accrualIndices The current accrual indices
     * @return AccrualIndices The updated accrual indices for the given asset.
     */
    function getCurrentAccrualIndices(
        IInterestRateCalculator _interestRateCalculator,
        uint256 _lastActivityBlockTimestamp,
        HubSpokeStructs.StoredVaultAmount memory _globalAssetAmounts,
        HubSpokeStructs.AccrualIndices memory _accrualIndices,
        uint256 _interestAccrualIndexPrecision
    ) public view returns (HubSpokeStructs.AccrualIndices memory) {
        uint256 secondsElapsed = block.timestamp - _lastActivityBlockTimestamp;
        if (secondsElapsed != 0 && _globalAssetAmounts.amounts.borrowed != 0 && _globalAssetAmounts.amounts.deposited != 0) {
            (uint256 depositInterestFactor, uint256 borrowInterestFactor, uint256 precision) = _interestRateCalculator
                .computeSourceInterestFactor(
                    secondsElapsed,
                    applyInterest(_globalAssetAmounts, _accrualIndices),
                    _interestAccrualIndexPrecision
                );

            _accrualIndices.borrowed = _accrualIndices.borrowed * borrowInterestFactor / precision;
            _accrualIndices.deposited = _accrualIndices.deposited * depositInterestFactor / precision;
        }
        return _accrualIndices;
    }

    function applyInterest(HubSpokeStructs.StoredVaultAmount memory vaultAmount, HubSpokeStructs.AccrualIndices memory indices) public pure returns (HubSpokeStructs.DenormalizedVaultAmount memory) {
        // no need to check the deposit index
        // if the borrow index didn't change then the deposit index didn't either
        if (indices.borrowed == vaultAmount.accrualIndices.borrowed) {
            // the amounts are already up to date
            // no need to recompute
            return vaultAmount.amounts;
        }

        return HubSpokeStructs.DenormalizedVaultAmount({
            deposited: vaultAmount.amounts.deposited == 0 ? 0 : vaultAmount.amounts.deposited * indices.deposited / vaultAmount.accrualIndices.deposited,
            borrowed: vaultAmount.amounts.borrowed == 0 ? 0 : vaultAmount.amounts.borrowed * indices.borrowed / vaultAmount.accrualIndices.borrowed
        });
    }

    function getVaultAmounts(address _vaultOwner, bytes32 _asset) public view returns (HubSpokeStructs.DenormalizedVaultAmount memory) {
        HubSpokeStructs.StoredVaultAmount memory vault = HubStorage.getAssetState(_asset).userVaults[_vaultOwner];
        return applyInterest(vault, getCurrentAccrualIndices(_asset));
    }

    function getGlobalAmounts(bytes32 _asset) public view returns (HubSpokeStructs.DenormalizedVaultAmount memory) {
        HubSpokeStructs.StoredVaultAmount memory total = HubStorage.getAssetState(_asset).totals;
        return applyInterest(total, getCurrentAccrualIndices(_asset));
    }
}