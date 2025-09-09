// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWormholeTunnel} from "./IWormholeTunnel.sol";

interface ISpoke {

    error CreditLimitExceeded();
    error CustodyLimitExceeded();
    error FundsAlreadyReleased();
    error InsufficientMsgValue();
    error InsufficientFunds();
    error InvalidAction();
    error InvalidAmount();
    error InvalidCostForReturnDeliveryLength();
    error InvalidDeliveryCost();
    error InvalidReleaseFundsPayload();
    error OnlyHubSender();
    error OnlyWormholeTunnel();
    error TransactionLimitExceeded();
    error TransferFailed();
    error UnusedParameterMustBeZero();

    function releaseFunds(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable;

    function topUp(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable;

    function confirmCredit(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable;

    function finalizeCredit(
        IWormholeTunnel.MessageSource calldata source,
        IERC20 token,
        uint256 amount,
        bytes calldata payload
    ) external payable;
}
