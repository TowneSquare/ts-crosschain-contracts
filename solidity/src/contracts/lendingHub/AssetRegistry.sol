// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IWETH} from "@wormhole/interfaces/IWETH.sol";

import "../../interfaces/IERC20decimals.sol";
import {IAssetRegistry} from "../../interfaces/IAssetRegistry.sol";
import "../HubSpokeStructs.sol";
import "../HubSpokeEvents.sol";
import {AssetRegistryMigrator} from "../migration/AssetRegistryMigrator.sol";


//contract AssetRegistry is IAssetRegistry, OwnableUpgradeable {
contract AssetRegistry is OwnableUpgradeable, AssetRegistryMigrator {
    event AssetRegistered(
        bytes32 asset,
        uint256 collateralizationRatioDeposit,
        uint256 collateralizationRatioBorrow,
        uint256 borrowLimit,
        uint256 supplyLimit,
        address interestRateCalculator,
        uint256 maxLiquidationBonus
    );
    event AssetRemoved(bytes32 asset);
    event CollateralizationRatiosChanged(bytes32 asset, uint256 collateralizationRatioDeposit, uint256 collateralizationRatioBorrow);
    event LimitsChanged(bytes32 asset, uint256 supplyLimit, uint256 borrowLimit);
    event LiquidationBonusChanged(bytes32 asset, uint256 bonus);
    event InterestRateCalculatorChanged(bytes32 asset, address calculator);
    event AssetBindingAdded(bytes32 id, uint16 chainId, bytes32 assetAddress);
    event AssetBindingRemoved(bytes32 id, uint16 chainId, bytes32 assetAddress);

    error DepositCollateralizationRatioTooLow();
    error BorrowCollateralizationRatioTooLow();
    error AssetAlreadyRegistered();
    error AssetNotRegistered();
    error TooManyDecimalsInAnAsset();
    error InvalidInput();

    modifier requireAsset(bytes32 _id) {
        if (!assetExists(_id)) {
            revert AssetNotRegistered();
        }
        _;
    }

    uint8 public constant override PROTOCOL_MAX_DECIMALS = 18;
    uint256 public constant override COLLATERALIZATION_RATIO_PRECISION = 1e6;
    uint256 public constant override LIQUIDATION_BONUS_PRECISION = 1e6;
    IWETH public immutable override WETH;

    bytes32[] registeredAssets;
    uint16[] spokeChains;

    // id => AssetInfo struct
    mapping(bytes32 => AssetInfo) assetInfos;
    // id => chain => address
    mapping(bytes32 => mapping(uint16 => bytes32)) assetAddresses;
    // chain => address => id
    mapping(uint16 => mapping(bytes32 => bytes32)) assetIds;
    // id => name
    mapping(bytes32 => string) assetNames;

    constructor(IWETH _WETH) {
        WETH = _WETH;
    }

    function initialize() external initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
    }

    function initializeWithMigration() external initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        migrate();
    }

    //
    // GETTERS
    //

    function getAssetId(string memory _name) public pure override returns (bytes32) {
        return keccak256(abi.encode(_name));
    }

    function getAssetId(uint16 _chainId, bytes32 _address) public view override returns (bytes32) {
        return assetIds[_chainId][_address];
    }

    function getAssetName(bytes32 _assetId) public view override returns (string memory) {
        return assetNames[_assetId];
    }

    function getAssetName(uint16 _chainId, bytes32 _address) external view override returns (string memory) {
        return getAssetName(getAssetId(_chainId, _address));
    }

    function assetExists(string memory _name) public view override returns (bool) {
        return assetExists(getAssetId(_name));
    }

    function assetExists(bytes32 _id) public view override returns (bool) {
        return assetInfos[_id].exists;
    }

    function getAssetInfo(string memory _name) public view override returns (AssetInfo memory) {
        return getAssetInfo(getAssetId(_name));
    }

    function getAssetInfo(bytes32 _id) public view override returns (AssetInfo memory) {
        return assetInfos[_id];
    }

    function getAssetAddress(string memory _name, uint16 _chainId) public view override returns (bytes32) {
        return getAssetAddress(getAssetId(_name), _chainId);
    }

    function getAssetAddress(bytes32 _id, uint16 _chainId) public view override returns (bytes32) {
        return assetAddresses[_id][_chainId];
    }

    function requireAssetAddress(bytes32 _id, uint16 _chainId) public view override returns (bytes32) {
        if (assetAddresses[_id][_chainId] == bytes32(0)) {
            revert AssetNotRegistered();
        }
        return assetAddresses[_id][_chainId];
    }

    function getRegisteredAssets() public view override returns (bytes32[] memory) {
        return registeredAssets;
    }

    function getSupportedChains() external view returns (uint16[] memory) {
        return spokeChains;
    }

    //
    // SETTERS
    //

    function setCollateralizationRatios(string memory _name, uint256 _deposit, uint256 _borrow) public override {
        setCollateralizationRatios(getAssetId(_name), _deposit, _borrow);
    }

    function setCollateralizationRatios(bytes32 _id, uint256 _deposit, uint256 _borrow) public override onlyOwner requireAsset(_id) {
        if (_deposit < COLLATERALIZATION_RATIO_PRECISION) {
            revert DepositCollateralizationRatioTooLow();
        }

        if (_borrow < COLLATERALIZATION_RATIO_PRECISION) {
            revert BorrowCollateralizationRatioTooLow();
        }

        AssetInfo storage assetInfo = assetInfos[_id];
        assetInfo.collateralizationRatioDeposit = _deposit;
        assetInfo.collateralizationRatioBorrow = _borrow;

        emit CollateralizationRatiosChanged(_id, _deposit, _borrow);
    }

    function setLimits(string memory _name, uint256 _deposit, uint256 _borrow) public override {
        setLimits(getAssetId(_name), _deposit, _borrow);
    }

    function setLimits(bytes32 _id, uint256 _deposit, uint256 _borrow) public override onlyOwner requireAsset(_id) {
        AssetInfo storage assetInfo = assetInfos[_id];
        assetInfo.supplyLimit = _deposit;
        assetInfo.borrowLimit = _borrow;

        emit LimitsChanged(_id, _deposit, _borrow);
    }

    function setMaxLiquidationBonus(string memory _name, uint256 _bonus) public override {
        setMaxLiquidationBonus(getAssetId(_name), _bonus);
    }

    function setMaxLiquidationBonus(bytes32 _id, uint256 _bonus) public override onlyOwner requireAsset(_id) {
        if (_bonus < LIQUIDATION_BONUS_PRECISION) {
            revert InvalidInput();
        }
        AssetInfo storage assetInfo = assetInfos[_id];
        assetInfo.maxLiquidationBonus = _bonus;

        emit LiquidationBonusChanged(_id, _bonus);
    }

    function setInterestRateCalculator(string memory _name, address _calculator) public override {
        setInterestRateCalculator(getAssetId(_name), _calculator);
    }

    function setInterestRateCalculator(bytes32 _id, address _calculator) public override onlyOwner requireAsset(_id) {
        AssetInfo storage assetInfo = assetInfos[_id];
        assetInfo.interestRateCalculator = _calculator;

        emit InterestRateCalculatorChanged(_id, _calculator);
    }

    //
    // INTERACTIONS
    //

    /**
     * @notice Registers asset on the hub. Only registered assets are allowed to be stored in the protocol.
     *
     * @param assetName: The address to be checked
     * @param collateralizationRatioDeposit: collateralizationRatioDeposit = crd * collateralizationRatioPrecision,
     * where crd is such that when we calculate 'fair prices' to see if a vault, after an action, would have positive
     * value, for purposes of allowing withdraws, borrows, or liquidations, we multiply any deposited amount of this
     * asset by crd.
     * @param collateralizationRatioBorrow: collateralizationRatioBorrow = crb * collateralizationRatioPrecision,
     * where crb is such that when we calculate 'fair prices' to see if a vault, after an action, would have positive
     * value, for purposes of allowing withdraws, borrows, or liquidations, we multiply any borrowed amount of this
     * asset by crb. One way to think about crb is that for every '$1 worth' of effective deposits we allow $c worth of
     * this asset borrowed
     * @param interestRateCalculator: Address of the interest rate calculator for this asset
     * @param maxLiquidationBonus: maxLiquidationBonus is a percent that defines how much of that asset can be claimed
     * by a liquidator and how much bonus they get for liquidating
     * @param supplyLimit How much of the asset can be supplied in total
     * @param borrowLimit How much of the asset can be borrowed in total
     */
    function registerAsset(
        string memory assetName,
        uint8 decimals,
        uint256 collateralizationRatioDeposit,
        uint256 collateralizationRatioBorrow,
        address interestRateCalculator,
        uint256 maxLiquidationBonus,
        uint256 supplyLimit,
        uint256 borrowLimit
    ) public override onlyOwner {
        bytes32 id = getAssetId(assetName);
        if (assetExists(id)) {
            revert AssetAlreadyRegistered();
        }

        assetNames[id] = assetName;

        if (collateralizationRatioDeposit < COLLATERALIZATION_RATIO_PRECISION) {
            revert DepositCollateralizationRatioTooLow();
        }
        if (collateralizationRatioBorrow < COLLATERALIZATION_RATIO_PRECISION) {
            revert BorrowCollateralizationRatioTooLow();
        }

        if (decimals > PROTOCOL_MAX_DECIMALS) {
            revert TooManyDecimalsInAnAsset();
        }

        AssetInfo storage info = assetInfos[id];
        info.collateralizationRatioDeposit = collateralizationRatioDeposit;
        info.collateralizationRatioBorrow = collateralizationRatioBorrow;
        info.decimals = decimals;
        info.interestRateCalculator = interestRateCalculator;
        info.exists = true;
        info.borrowLimit = borrowLimit;
        info.supplyLimit = supplyLimit;
        info.maxLiquidationBonus = maxLiquidationBonus;

        registeredAssets.push(id);

        emit AssetRegistered(
            id,
            collateralizationRatioDeposit,
            collateralizationRatioBorrow,
            borrowLimit,
            supplyLimit,
            interestRateCalculator,
            maxLiquidationBonus
        );
    }

    // this drops support for the asset. the Hub will no longer recognize this asset after the TX completes
    function deregisterAsset(string memory _name) external override onlyOwner {
        bytes32 id = getAssetId(_name);
        if (!assetExists(id)) {
            revert AssetNotRegistered();
        }

        // unbind any leftovers
        for (uint256 i = 0; i < spokeChains.length; i++) {
            if (assetAddresses[id][spokeChains[i]] != bytes32(0)) {
                unbindAsset(id, spokeChains[i]);
            }
        }

        delete assetInfos[id];
        for (uint256 i = 0; i < registeredAssets.length; i++) {
            if (registeredAssets[i] == id) {
                registeredAssets[i] = registeredAssets[registeredAssets.length - 1];
                registeredAssets.pop();
            }
        }

        delete assetNames[id];

        emit AssetRemoved(id);
    }

    // binds a Spoke chain asset address to the asset identifier
    function bindAsset(string memory _name, uint16 _chainId, bytes32 _address) public override onlyOwner {
        bindAsset(getAssetId(_name), _chainId, _address);
    }

    function bindAssets(string memory _name, uint16[] calldata _chains, bytes32[] calldata _addresses) public override onlyOwner {
        bindAssets(getAssetId(_name), _chains, _addresses);
    }

    function bindAssets(bytes32 _id, uint16[] calldata _chains, bytes32[] calldata _addresses) public override onlyOwner {
        if (_chains.length != _addresses.length) {
            revert InvalidInput();
        }
        for (uint256 i = 0; i < _chains.length; i++) {
            bindAsset(_id, _chains[i], _addresses[i]);
        }
    }

    function bindAsset(bytes32 _id, uint16 _chainId, bytes32 _address) public onlyOwner requireAsset(_id) override {
        if (_id == bytes32(0) || _chainId == 0 || _address == bytes32(0)) {
            revert InvalidInput();
        }

        bool chainExists;
        for (uint256 i = 0; i < spokeChains.length; i++) {
            if (spokeChains[i] == _chainId) {
                chainExists = true;
                break;
            }
        }
        if (!chainExists) {
            spokeChains.push(_chainId);
        }
        assetAddresses[_id][_chainId] = _address;
        assetIds[_chainId][_address] = _id;

        emit AssetBindingAdded(_id, _chainId, _address);
    }

    // removes Spoke chain asset binding from the asset identifier
    function unbindAsset(string memory _name, uint16 _chainId) public override {
        unbindAsset(getAssetId(_name), _chainId);
    }

    function unbindAsset(uint16 _chainId, bytes32 _address) public override {
        unbindAsset(assetIds[_chainId][_address], _chainId);
    }

    function unbindAsset(bytes32 _id, uint16 _chainId) public override onlyOwner requireAsset(_id) {
        // _id non-zero is implied from requireAsset
        if (_chainId == 0 || assetAddresses[_id][_chainId] == bytes32(0)) {
            revert InvalidInput();
        }

        bytes32 assetAddress = assetAddresses[_id][_chainId];
        delete assetIds[_chainId][assetAddress];
        delete assetAddresses[_id][_chainId];

        emit AssetBindingRemoved(_id, _chainId, assetAddress);
    }

    // TODO: add sunsetting of an asset through linear increase of collateralization ratios over time?
}
