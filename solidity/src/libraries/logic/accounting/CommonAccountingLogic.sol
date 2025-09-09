// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "@wormhole/interfaces/IWETH.sol";

import {HubSpokeStructs} from "../../../contracts/HubSpokeStructs.sol";

library CommonAccountingLogic {
    using SafeERC20 for IERC20;

    error InsufficientMsgValue();
    error UnusedParameterMustBeZero();

    function handleInboundTokensAndAdjustAction(
        HubSpokeStructs.Action _action,
        address _asset,
        uint256 _amount,
        IWETH _weth
    ) public returns (
        HubSpokeStructs.Action action,
        address asset,
        uint256 amount
    ) {
        (action, asset, amount, ) = handleInboundTokensAndAdjustAction(_action, _asset, _amount, _weth, 0);
    }

    function handleInboundTokensAndAdjustAction(
        HubSpokeStructs.Action _action,
        address _asset,
        uint256 _amount,
        IWETH _weth,
        uint256 _cost
    ) public returns (
        HubSpokeStructs.Action action,
        address asset,
        uint256 amount,
        uint256 remainingMsgValue
    ) {
        action = _action;
        asset = _asset;
        amount = _amount;
        remainingMsgValue = msg.value;
        if (action == HubSpokeStructs.Action.RepayNative || action == HubSpokeStructs.Action.DepositNative) {
            if (asset != address(0) || amount != 0) revert UnusedParameterMustBeZero();
            if (msg.value <= _cost) {
                revert InsufficientMsgValue();
            }

            asset = address(_weth);
            amount = msg.value - _cost;
            _weth.deposit{value: amount}();
            action = action == HubSpokeStructs.Action.RepayNative ? HubSpokeStructs.Action.Repay : HubSpokeStructs.Action.Deposit;
            remainingMsgValue = _cost;
        } else if (action == HubSpokeStructs.Action.Deposit || action == HubSpokeStructs.Action.Repay) {
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
        // the else case here is that the action was a Withdraw (+native) or a Borrow, which have no inbound tokens
        // or asset address to adjust, in such case, this function is a no-op pass-through
    }
}