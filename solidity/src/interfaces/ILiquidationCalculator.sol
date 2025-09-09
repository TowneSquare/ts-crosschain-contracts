// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../contracts/HubSpokeStructs.sol";

interface ILiquidationCalculator {
    enum RepaymentMethod {
        TOKEN_TRANSFER,
        FROM_DEPOSIT,
        DEBT_TAKEOVER
    }

    enum PaymentMethod {
        TOKEN_TRANSFER,
        DEPOSIT_TAKEOVER
    }

    /**
     * @param assetId - The ID of the repaid/received asset
     * @param repaidAmount - The amount of the asset that is being repaid (can be zero)
     * @param receivedAmount - The amount of the asset that is being received (can be zero)
     * @param depositTakeover - A flag if the liquidator will take the deposit of the debtor instead of collateral tokens
     * @param repayFromDeposit - A flag if the liquidator will repay from their existing deposit instead of providing tokens
     */
    struct DenormalizedLiquidationAsset {
        bytes32 assetId;
        uint256 repaidAmount;
        uint256 receivedAmount;
        RepaymentMethod repaymentMethod;
        PaymentMethod paymentMethod;
    }

    /**
     * @param vault - the address of the vault that is being liquidated
     */
    struct LiquidationInput {
        address vault;
        DenormalizedLiquidationAsset[] assets;
    }

    function getMaxHealthFactor() external view returns (uint256, uint256);
}
