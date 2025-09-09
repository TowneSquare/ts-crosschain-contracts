// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@wormhole/interfaces/IWETH.sol";
import "../contracts/HubSpokeStructs.sol";

interface IAssetRegistry {
    struct AssetInfo {
        uint256 collateralizationRatioDeposit;
        uint256 collateralizationRatioBorrow;
        uint8 decimals;
        address interestRateCalculator;
        bool exists;
        uint256 borrowLimit;
        uint256 supplyLimit;
        uint256 maxLiquidationBonus; // 1e6 precision; 130e4 = 130% = 1.3; the liquidator gets 30% over what he repays
        uint256[50] __gap;
    }

    function registerAsset(
        string memory assetName,
        uint8 decimals,
        uint256 collateralizationRatioDeposit,
        uint256 collateralizationRatioBorrow,
        address interestRateCalculator,
        uint256 maxLiquidationBonus,
        uint256 supplyLimit,
        uint256 borrowLimit
    ) external;

    function PROTOCOL_MAX_DECIMALS() external pure returns (uint8);
    function COLLATERALIZATION_RATIO_PRECISION() external pure returns (uint256);
    function LIQUIDATION_BONUS_PRECISION() external pure returns (uint256);

    function deregisterAsset(string memory _name) external;

    function getAssetId(string memory _name) external pure returns (bytes32);
    function getAssetId(uint16 _chainId, bytes32 _address) external view returns (bytes32);

    function getAssetName(bytes32 _assetId) external view returns (string memory);
    function getAssetName(uint16 _chainId, bytes32 _address) external view returns (string memory);

    function assetExists(string memory _name) external view returns (bool);
    function assetExists(bytes32 _id) external view returns (bool);

    function getAssetInfo(string memory _name) external view returns (AssetInfo memory);
    function getAssetInfo(bytes32 _id) external view returns (AssetInfo memory);

    function getAssetAddress(string memory _name, uint16 _chainId) external view returns (bytes32);
    function getAssetAddress(bytes32 _id, uint16 _chainId) external view returns (bytes32);
    function requireAssetAddress(bytes32 _id, uint16 _chainId) external view returns (bytes32);

    function getRegisteredAssets() external view returns (bytes32[] memory);
    function getSupportedChains() external view returns (uint16[] memory);

    function WETH() external view returns (IWETH);

    function setCollateralizationRatios(string memory _name, uint256 _deposit, uint256 _borrow) external;
    function setCollateralizationRatios(bytes32 _id, uint256 _deposit, uint256 _borrow) external;

    function setLimits(string memory _name, uint256 _deposit, uint256 _borrow) external;
    function setLimits(bytes32 _id, uint256 _deposit, uint256 _borrow) external;

    function setMaxLiquidationBonus(string memory _name, uint256 _bonus) external;
    function setMaxLiquidationBonus(bytes32 _id, uint256 _bonus) external;

    function setInterestRateCalculator(string memory _name, address _calculator) external;
    function setInterestRateCalculator(bytes32 _id, address _calculator) external;

    // binds a Spoke chain asset address to the asset identifier
    function bindAsset(string memory _name, uint16 _chainId, bytes32 _address) external;
    function bindAsset(bytes32 _id, uint16 _chainId, bytes32 _address) external;
    function bindAssets(string memory _name, uint16[] calldata _chains, bytes32[] calldata _addresses) external;
    function bindAssets(bytes32 _id, uint16[] calldata _chains, bytes32[] calldata _addresses) external;
    // removes Spoke chain asset binding from the asset identifier
    function unbindAsset(string memory _name, uint16 _chainId) external;
    function unbindAsset(bytes32 _id, uint16 _chainId) external;
    function unbindAsset(uint16 _chainId, bytes32 _address) external;
}
