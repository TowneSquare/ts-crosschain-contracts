// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IHub.sol";
import "../interfaces/ILiquidator.sol";
import "../contracts/HubSpokeStructs.sol";
import "@wormhole/Utils.sol";

contract Liquidator is ILiquidator, Ownable {
    using SafeERC20 for IERC20;

    IHub public hub;
    mapping(address => bool) liquidators;

    constructor(IHub _hub, address[] memory _liquidators) Ownable(msg.sender) {
        hub = _hub;
        for (uint256 i = 0; i < _liquidators.length; i++) {
            addLiquidator(_liquidators[i]);
        }
    }

    modifier onlyLiquidator() {
        if (!isLiquidator(msg.sender)) {
            revert OnlyLiquidator();
        }
        _;
    }

    function isLiquidator(address _liquidator) public view override returns (bool) {
        return liquidators[_liquidator];
    }

    function addLiquidator(address _liquidator) public override onlyOwner {
        liquidators[_liquidator] = true;
        emit LiquidatorStatusChanged(_liquidator, true);
    }

    function removeLiquidator(address _liquidator) public override onlyOwner {
        liquidators[_liquidator] = false;
        emit LiquidatorStatusChanged(_liquidator, false);
    }

    function confirmPairingRequest(uint16 _chainId, bytes32 _pairedAddress) external onlyOwner {
        hub.confirmPairingRequest(_chainId, _pairedAddress);
    }

    function withdraw(IERC20 _token, address _recipient, uint256 _amount) public virtual override onlyOwner {
        if (address(_token) == address(0) || _recipient == address(0)) {
            revert NoZeroAddress();
        }
        if (_token.balanceOf(address(this)) < _amount) {
            revert InsufficientBalance();
        }
        _token.safeTransfer(_recipient, _amount);
        emit Withdraw(_token, _recipient, _amount);
    }

    function withdrawHubDeposit(bytes32 _asset, uint256 _amount) external virtual override onlyOwner {
        hub.userActions(HubSpokeStructs.Action.Withdraw, _asset, _amount);
    }

    function liquidation(ILiquidationCalculator.LiquidationInput memory input) public virtual override onlyLiquidator {
        _liquidation(input);
    }

    function _liquidation(ILiquidationCalculator.LiquidationInput memory input) internal {
        uint16 hubChainId = hub.getWormholeTunnel().chainId();
        uint256 valueOfRepays = 0;
        uint256 valueOfReceives = 0;
        IHubPriceUtilities hpu = hub.getPriceUtilities();
        for (uint256 i = 0; i < input.assets.length; i++) {
            ILiquidationCalculator.DenormalizedLiquidationAsset memory asset = input.assets[i];
            if (asset.repaidAmount > 0 && asset.repaymentMethod == ILiquidationCalculator.RepaymentMethod.TOKEN_TRANSFER) {
                IAssetRegistry assetRegistry = hub.getAssetRegistry();
                address hubChainAssetAddress = fromWormholeFormat(assetRegistry.getAssetAddress(asset.assetId, hubChainId));
                if (hubChainAssetAddress == address(0)) {
                    revert AssetNotOnHubChain();
                }
                IERC20(hubChainAssetAddress).approve(address(hub), asset.repaidAmount);
            }
            HubSpokeStructs.NotionalVaultAmount memory valueOfAsset = hpu.calculateNotionals(
                asset.assetId,
                HubSpokeStructs.DenormalizedVaultAmount(asset.receivedAmount, asset.repaidAmount)
            );
            valueOfReceives += valueOfAsset.deposited;
            valueOfRepays += valueOfAsset.borrowed;
        }

        if (valueOfReceives < valueOfRepays) {
            revert UnprofitableLiquidation();
        }

        hub.liquidation(input);
    }
}