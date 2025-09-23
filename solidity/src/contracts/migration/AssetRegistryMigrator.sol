// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILegacyAssetRegistry} from "../../interfaces/ILegacyAssetRegistry.sol";
import {IAssetRegistry} from "../../interfaces/IAssetRegistry.sol";
import {toWormholeFormat} from "@wormhole/Utils.sol";

// Wormhole wrapped tokens implement this interface
interface IBridgeToken {
    function nativeContract() external view returns (bytes32);
    function chainId() external view returns (uint16);
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}


abstract contract AssetRegistryMigrator is IAssetRegistry {
    address private constant LEGACY_ASSET_REGISTRY = 0x6510D7705dF7Ad4923B9699A1af4c72894087631;
    uint16 private constant HUB_CHAIN_ID = 23;

    error InvalidSymbol();
    error InvalidDecimals();
    error InvalidInterestRateCalculator();

    function registerAsset(
        string memory assetName,
        uint8 decimals,
        uint256 collateralizationRatioDeposit,
        uint256 collateralizationRatioBorrow,
        address interestRateCalculator,
        uint256 maxLiquidationBonus,
        uint256 supplyLimit,
        uint256 borrowLimit
    ) public virtual override {}
    function bindAsset(bytes32 _id, uint16 _chainId, bytes32 _address) public virtual override {}
    function setCollateralizationRatios(string memory _name, uint256 _deposit, uint256 _borrow) public virtual override {}
    function setLimits(string memory _name, uint256 _deposit, uint256 _borrow) public virtual override {}
    function setMaxLiquidationBonus(string memory _name, uint256 _bonus) public virtual override {}

    function getSymbolMainnet(address _addr) internal pure returns (string memory) {
        if (
            _addr == 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 ||
            _addr == 0xD8369C2EDA18dD6518eABb1F85BD60606dEb39Ec ||
            _addr == 0xB1fC645a86fB5085e12D8BDDb77702F728D2A26F ||
            _addr == 0xBAfbCB010D920e0Dab9DFdcF634De1B777028a85 ||
            _addr == 0xAe81a542e20270b48Bd5297E3e0f280f79E46C42
        ) {
            return "WETH";
        } else if (
            _addr == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 ||
            _addr == 0x99ED7E54ed287f8e603bcA5932abFA812EEC4f3c
        ) {
            return "USDC";
        } else if (
            _addr == 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 ||
            _addr == 0xE4728F3E48E94C6DA2B53610E677cc241DAFB134 ||
            _addr == 0x16A9d7FECE7Feb0d8ece07483E5d80f52c0a6e31
        ) {
            return "USDT";
        } else if (
            _addr == 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f ||
            _addr == 0x397846a8078d4845c7f5c6Ca76aeBbcFDc044fAe ||
            _addr == 0xD0D541CeB4B8d412E02d3F290Aa67Ff748749758
        ) {
            return "WBTC";
        } else if (
            _addr == 0x5979D7b546E38E414F7E9822514be443A4800529 ||
            _addr == 0xf2717122Dfdbe988ae811E7eFB157aAa07Ff9D0F ||
            _addr == 0xf99C5EEd186601955a9a1027536D1b46b1f909F8
        ) {
            return "WSTETH";
        } else if (_addr == 0x912CE59144191C1204E64559FE8253a0e49E6548) {
            return "ARB";
        } else if (_addr == 0x3Ac2EBFf77Aab7cA87FC0e4e1c1b4a5E219957C2) {
            return "OP";
        } else if (
            _addr == 0xDfF1788518DBF654aa1c3f75DA2E01A7e00AE425 ||
            _addr == 0xA98dEB49304b6Fd9509b200AE723042e460229e0
        ) {
            return "WEETH";
        } else if (_addr == 0x2d501d3e9cDAF8b80A17B99F7C47dC02376139C6) {
            return "CBETH";
        } else if (
            _addr == 0x47c031236e19d024b42f8AE6780E44A573170703
        ) {
            return "GMBTC";
        } else if (
            _addr == 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336
        ) {
            return "GMETH";
        } else if (
            _addr == 0x57723abc582DBfE11Ea01f1A1f48aEE20bD65D73 ||
            _addr == 0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40 ||
            _addr == 0x2519010b6585247BcDC8BcDa5C8730Be754b8c76 ||
            _addr == 0x761213993383aB05434f1D2f9CBc4c2246636532
        ) {
            return "TBTC";
        } else if (
            _addr == 0x2416092f143378750bb29b79eD961ab195CcEea5 ||
            _addr == 0x3d3e2303bEDA9d1bA8e43a5C832fc5bfB13A3a15
        ) {
            return "EZETH";
        } else if (_addr == 0xfC0FD25590C93BFf6449b2B33f2d1518f32B6342) {
            return "PXETH";
        } else if (_addr == 0xB428bFc1a86C34921269eA460B843E9953A70416) {
            return "APXETH";
        } else if (
            _addr == 0x7F9aD3f6202E06F0BA18468E308b3fb42D1cD166 ||
            _addr == 0xB77f5bCd96F2bdBc782adb0597Da005F74c2d1A7
        ) {
            return "SUSDE";
        } else if (_addr == 0xd10142634239176cFc24CF1e39D6c26b9375896C) {
            return "USDE";
        } else {
            revert("Address not found");
        }
    }

    function migrate() internal {
        address[] memory assets = ILegacyAssetRegistry(LEGACY_ASSET_REGISTRY).getRegisteredAssets();
        for(uint256 i = 0; i < assets.length; i++) {
            migrateAsset(assets[i]);
        }
    }

    function migrateAsset(address assetAddress) internal {
        ILegacyAssetRegistry.AssetInfo memory oldAssetInfo =
            ILegacyAssetRegistry(LEGACY_ASSET_REGISTRY).getAssetInfo(assetAddress);
        string memory symbol = getSymbolMainnet(assetAddress);

        migrateAssetInfo(symbol, oldAssetInfo);
        bindNewAsset(symbol, assetAddress);
    }

    function migrateAssetInfo(
        string memory symbol,
        ILegacyAssetRegistry.AssetInfo memory oldAssetInfo
    ) internal {
        IAssetRegistry.AssetInfo memory newAssetInfo = IAssetRegistry(address(this)).getAssetInfo(symbol);
        if(!newAssetInfo.exists) {
//            IAssetRegistry(assetRegistry).registerAsset(
            registerAsset(
                symbol,
                oldAssetInfo.decimals,
                oldAssetInfo.collateralizationRatioDeposit,
                oldAssetInfo.collateralizationRatioBorrow,
                oldAssetInfo.interestRateCalculator,
                oldAssetInfo.maxLiquidationBonus,
                oldAssetInfo.supplyLimit,
                oldAssetInfo.borrowLimit
            );
        } else {
            if(oldAssetInfo.decimals != newAssetInfo.decimals) {
                revert InvalidDecimals();
            }
            if(oldAssetInfo.interestRateCalculator != newAssetInfo.interestRateCalculator) {
                revert InvalidInterestRateCalculator();
            }

            uint256 crd = max(oldAssetInfo.collateralizationRatioDeposit, newAssetInfo.collateralizationRatioDeposit);
            uint256 crb = max(oldAssetInfo.collateralizationRatioBorrow, newAssetInfo.collateralizationRatioBorrow);
            uint256 maxLiquidationBonus = max(oldAssetInfo.maxLiquidationBonus, newAssetInfo.maxLiquidationBonus);
            uint256 borrowLimit = oldAssetInfo.borrowLimit + newAssetInfo.borrowLimit;
            uint256 supplyLimit = oldAssetInfo.supplyLimit + newAssetInfo.supplyLimit;

            setCollateralizationRatios(symbol, crd, crb);
            setLimits(symbol, supplyLimit, borrowLimit);
            setMaxLiquidationBonus(symbol, maxLiquidationBonus);
        }

    }

    function bindNewAsset(string memory symbol, address assetAddress) internal {
        if(isBridgeToken(assetAddress)) {
            uint16 chainId = IBridgeToken(assetAddress).chainId();
            bytes32 baseChainAddress = IBridgeToken(assetAddress).nativeContract();
            bindAsset(_getAssetId(symbol), chainId, baseChainAddress);
        } else {
            bytes32 baseChainAddress = toWormholeFormat(assetAddress);
            bytes32 assetId = _getAssetId(symbol);
            bindAsset(assetId, HUB_CHAIN_ID, baseChainAddress);
            if (_getAssetId("USDC") == assetId) {
                // bind other Spoke CCTP USDC addresses
                bindAsset(assetId, 2, toWormholeFormat(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // ETH
                bindAsset(assetId, 24, toWormholeFormat(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85)); // OP
                bindAsset(assetId, 30, toWormholeFormat(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // BASE
                bindAsset(assetId, 1, 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61); // SOL
            }
        }

    }

    // Check if asset is native to Hub chain or Wormhole Wrapped token which implements IBridgeToken
    function isBridgeToken(address assetAddress) internal view returns(bool) {
        (bool chainIdCheck, ) = assetAddress.staticcall(
            abi.encodeWithSelector(IBridgeToken.chainId.selector)
        );
        (bool nativeContractCheck, ) = assetAddress.staticcall(
            abi.encodeWithSelector(IBridgeToken.nativeContract.selector)
        );

        return chainIdCheck && nativeContractCheck;
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? a : b;
    }

    function _getAssetId(string memory _name) internal pure returns (bytes32) {
        return keccak256(abi.encode(_name));
    }

}