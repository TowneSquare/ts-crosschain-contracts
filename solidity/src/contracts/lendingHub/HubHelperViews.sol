// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../HubSpokeStructs.sol";
import "../../interfaces/IInterestRateCalculator.sol";
import "../../interfaces/IHubPriceUtilities.sol";
import "../../interfaces/IHub.sol";
import "../../interfaces/IAssetRegistry.sol";
import "@wormhole/Utils.sol";

contract HubHelperViews {

    IHub hub;

    struct AssetLiquidity {
        uint16 chainId;
        bytes32 chainAddress;
        uint256 available;
    }

    constructor(address _hub) {
        hub = IHub(_hub);
    }

    /**
     * @dev Get the maximum amount of an asset that can be borrowed by a vault owner
     *
     * @param vaultOwner - The address of the owner of the vault
     * @param assetId - The ID of the relevant asset
     * @param chainId - The ID of the chain to withdraw/borrow to
     * @param minHealth - The minimum health of the vault after the borrow
     * @param minHealthPrecision - The precision of the minimum health
     * @return maxBorrowableAmount - The maximum amount of the asset that can be borrowed by the vault owner
     * @return availableLiquidity - The amount of tokens available on the Hub or on the Spoke (depending on chainId)
     */
    function getMaxBorrowableAmount(
        address vaultOwner,
        bytes32 assetId,
        uint16 chainId,
        uint256 minHealth,
        uint256 minHealthPrecision
    ) external view returns (uint256 maxBorrowableAmount, uint256 availableLiquidity) {
        (, maxBorrowableAmount, availableLiquidity) = calculateMaxWithdrawableAndBorrowableAmounts(assetId, chainId, vaultOwner, minHealth, minHealthPrecision);
    }

    /**
     * @notice Get the maximum amount of an asset that can be borrowed by a vault owner after a deposit or withdrawal
     *
     * @param assetId - The ID of the relevant asset
     * @param chainId - The ID of the chain to withdraw/borrow to
     * @param vaultOwner - The address of the owner of the vault
     * @param minHealth - The minimum health of the vault after the borrow
     * @param minHealthPrecision - The precision of the minimum health
     * @return maxWithdrawableAmount - The maximum amount of the asset that can be withdrawn by the vault owner
     * @return maxBorrowableAmount - The maximum amount of the asset that can be borrowed by the vault owner
     * @return availableLiquidity - The amount of tokens available on the Hub or on the Spoke (depending on chainId)
     */
    function calculateMaxWithdrawableAndBorrowableAmounts(
        bytes32 assetId,
        uint16 chainId,
        address vaultOwner,
        uint256 minHealth,
        uint256 minHealthPrecision
    )
        internal
        view
        returns (uint256 maxWithdrawableAmount, uint256 maxBorrowableAmount, uint256 availableLiquidity)
    {

        availableLiquidity = getAvailableLiquidity(assetId, chainId);

        if (availableLiquidity == 0) {
            return (0,0,0);
        }

        IHubPriceUtilities hubPriceUtilities = IHubPriceUtilities(address(hub.getPriceUtilities()));
        HubSpokeStructs.NotionalVaultAmount memory notionals = hubPriceUtilities.getVaultEffectiveNotionals(vaultOwner, true);

        if (notionals.deposited * minHealthPrecision <= notionals.borrowed * minHealth) {
            // if the vault is already below the target health, return zero amounts
            return (0, 0, availableLiquidity);
        }

        uint256 prevDeposit = notionals.deposited;
        if (notionals.borrowed > 0) {
            // only limit the withdraw amount if there is debt
            // this will not underflow beacause of the previous check
            // get the maximum notional value that is withdrawable or borrowable given the minHealth
            notionals.deposited -= (notionals.borrowed * minHealth / minHealthPrecision);
        }

        // notionals.deposited >= (notionals.borrowed + maxNotionalBorrowRetainingHealth) * _minHealth / _minHealthPrecision
        // notionals.deposited * _minHealthPrecision / _minHealth - notionals.borrowed >= maxNotionalBorrowRetainingHealth
        notionals.borrowed = prevDeposit * minHealthPrecision / minHealth - notionals.borrowed;


        HubSpokeStructs.DenormalizedVaultAmount memory amounts;
        {
            // realValues.deposited will be the value of the asset that can be withdrawn
            // realValues.borrowed will be the value of the asset that can be borrowed
            HubSpokeStructs.NotionalVaultAmount memory realValues = hubPriceUtilities.removeCollateralizationRatios(assetId, notionals);
            // invert the notional computation to get the asset amount
            amounts = hubPriceUtilities.invertNotionals(assetId, realValues);
        }

        // in case of withdrawal, take into account the real user deposit balance
        // in both cases, take into account the available liquidity
        HubSpokeStructs.DenormalizedVaultAmount memory realVaultAmounts = hub.getVaultAmounts(vaultOwner, assetId);
        maxWithdrawableAmount = amounts.deposited > realVaultAmounts.deposited ? realVaultAmounts.deposited : amounts.deposited;
        maxBorrowableAmount = amounts.borrowed;
    }

    /**
     * @notice Get the maximum amount of an asset that can be withdrawn by a vault owner
     *
     * @param vaultOwner - The address of the owner of the vault
     * @param assetId - The ID of the relevant asset
     * @param chainId - The ID of the chain
     * @param minHealth - The minimum health of the vault after the withdrawal
     * @param minHealthPrecision - The precision of the minimum health
     * @return maxWithdrawableAmount - The maximum amount of the asset that can be withdrawn by the vault owner
     * @return availableLiquidity - The amount of tokens available on the Hub or on the Spoke (depending on chainId)
     */
    function getMaxWithdrawableAmount(address vaultOwner, bytes32 assetId, uint16 chainId, uint256 minHealth, uint256 minHealthPrecision)
        external
        view
        returns (uint256 maxWithdrawableAmount, uint256 availableLiquidity)
    {
        (maxWithdrawableAmount,, availableLiquidity) = calculateMaxWithdrawableAndBorrowableAmounts(assetId, chainId, vaultOwner, minHealth, minHealthPrecision);
    }

    /**
     * @notice Get the current interest rate for an asset
     *
     * @param _name - the name of the asset
     * @return IInterestRateCalculator.InterestRates The current deposit interest rate for the asset, multiplied by rate precision
     */
    function getCurrentInterestRate(string memory _name) external view returns (IInterestRateCalculator.InterestRates memory) {
        IAssetRegistry assetRegistry = IAssetRegistry(hub.getAssetRegistry());
        bytes32 assetId = assetRegistry.getAssetId(_name);
        IAssetRegistry.AssetInfo memory assetInfo = assetRegistry.getAssetInfo(assetId);
        IInterestRateCalculator assetCalculator = IInterestRateCalculator(assetInfo.interestRateCalculator);
        HubSpokeStructs.DenormalizedVaultAmount memory denormalizedGlobals = hub.getGlobalAmounts(assetId);
        return assetCalculator.currentInterestRate(denormalizedGlobals);
    }

    /**
     * @notice Get the reserve factor and precision for a given asset
     *
     * @param _name - The name of the asset
     * @return reserveFactor - The reserve factor for the asset
     * @return reservePrecision - The precision of the reserve factor
     */
    function getReserveFactor(string memory _name) external view returns (uint256, uint256) {
        IAssetRegistry assetRegistry = IAssetRegistry(hub.getAssetRegistry());
        IAssetRegistry.AssetInfo memory assetInfo = assetRegistry.getAssetInfo(_name);
        address assetCalculator = assetInfo.interestRateCalculator;
        return IInterestRateCalculator(assetCalculator).getReserveFactorAndPrecision();
    }

    /**
     * @notice Get a user's account balance in an asset
     *
     * @param vaultOwner - the address of the user
     * @param assetId - the ID of the asset
     * @return VaultAmount a struct with 'deposited' field and 'borrowed' field for the amount deposited and borrowed of the asset
     * multiplied by 10^decimal for that asset. Values are denormalized.
     */
    function getUserBalance(address vaultOwner, bytes32 assetId)
        public
        view
        returns (HubSpokeStructs.DenormalizedVaultAmount memory)
    {
        return hub.getVaultAmounts(vaultOwner, assetId);
    }

    /**
     * @notice Get the protocol's global balance in an asset
     *
     * @param assetId - the ID of the asset
     * @return VaultAmount a struct with 'deposited' field and 'borrowed' field for the amount deposited and borrowed of the asset
     * multiplied by 10^decimal for that asset. Values are denormalized.
     */
    function getGlobalBalance(bytes32 assetId) public view returns (HubSpokeStructs.DenormalizedVaultAmount memory) {
        return hub.getGlobalAmounts(assetId);
    }

    /**
     * @notice Get the protocol's global reserve amount in an asset
     *
     * @param assetId - the ID of the asset
     * @return uint256 The amount of the asset in the protocol's reserve
     */
    function getReserveAmount(bytes32 assetId) external view returns (uint256) {
        return hub.getReserveAmount(assetId);
    }

    function getAvailableLiquidity(bytes32 assetId, uint16 chainId) public view returns (uint256) {
        IAssetRegistry assetRegistry = hub.getAssetRegistry();
        uint16 hubChainId = hub.getWormholeTunnel().chainId();
        bytes32 chainAddress = assetRegistry.getAssetAddress(assetId, chainId);
        if (chainId == hubChainId) {
            return IERC20(fromWormholeFormat(chainAddress)).balanceOf(address(hub));
        }

        return hub.getSpokeBalances(chainId, chainAddress).finalized;

        // TODO: add tests. doublecheck logic
        // reserve = balance - spokeBalance + spokePending + totalBorrow - totalDeposit
        // totalLiquidity = balance - reserve
        // totalLiquidity = spokeBalance - spokePending - totalBorrow + totalDeposit
        // spokeLiquidity = spokeBalance
        // hubLiquidity = totalDeposit - totalBorrow - spokePending
        // HubSpokeStructs.DenormalizedVaultAmount memory globalBalance = getGlobalBalance(assetId);
        // HubSpokeStructs.HubSpokeBalances memory spokeBalance = hub.getSpokeBalances(assetId);
        // spokeLiquidity = spokeBalance.finalized;
        // hubLiquidity = globalBalance.deposited - globalBalance.borrowed - spokeBalance.unfinalized;
    }
}
