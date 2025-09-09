// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../contracts/HubSpokeStructs.sol";
import "./ILiquidationCalculator.sol";
import "./IHubPriceUtilities.sol";
import "./IAssetRegistry.sol";
import {IWormholeTunnel} from "./IWormholeTunnel.sol";

/**
 * @notice interface for external contracts that need to access Hub state
 */
interface IHub {
    function checkVaultHasAssets(address vault, bytes32 assetId, uint256 normalizedAmount)
        external
        view;

    function checkProtocolGloballyHasAssets(
        bytes32 assetId,
        uint256 normalizedAmount
    ) external view;

    function checkProtocolGloballyHasAssets(
        bytes32 assetId,
        uint256 normalizedAmount,
        uint256 borrowLimit
    ) external view;

    function getInterestAccrualIndices(bytes32 assetId)
        external
        view
        returns (HubSpokeStructs.AccrualIndices memory);

    function getInterestAccrualIndexPrecision() external view returns (uint256);

    function getVaultAmounts(address vaultOwner, bytes32 assetId)
        external
        view
        returns (HubSpokeStructs.DenormalizedVaultAmount memory);

    function getCurrentAccrualIndices(bytes32 assetId)
        external
        view
        returns (HubSpokeStructs.AccrualIndices memory);

    function updateAccrualIndices(bytes32 assetId) external;

    function getLastActivityBlockTimestamp(bytes32 assetId) external view returns (uint256);

    function getGlobalAmounts(bytes32 assetId) external view returns (HubSpokeStructs.DenormalizedVaultAmount memory);

    function getReserveAmount(bytes32 assetId) external view returns (uint256);

    function getSpokeBalances(uint16 chainId, bytes32 homeAddress) external view returns (HubSpokeStructs.HubSpokeBalances memory);

    function getSpokeBalances(bytes32 assetId) external view returns (HubSpokeStructs.HubSpokeBalances memory);

    function getLiquidationCalculator() external view returns (ILiquidationCalculator);

    function getPriceUtilities() external view returns (IHubPriceUtilities);

    function getAssetRegistry() external view returns (IAssetRegistry);

    function getWormholeTunnel() external view returns (IWormholeTunnel);

    function getLiquidationFeeAndPrecision() external view returns (uint256, uint256);

    function liquidation(ILiquidationCalculator.LiquidationInput memory input) external;

    function userActions(HubSpokeStructs.Action action, bytes32 asset, uint256 amount) external payable;

    function confirmPairingRequest(uint16 _chainId, bytes32 _account) external;

    // ----- cross chain message handlers ---

    function userActionMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable;

    function instantActionMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external;

    function finalizeCreditMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external;

    function confirmTopUpMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external;

    function confirmFixLostCreditMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external;

    function pairingRequestMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external;
}
