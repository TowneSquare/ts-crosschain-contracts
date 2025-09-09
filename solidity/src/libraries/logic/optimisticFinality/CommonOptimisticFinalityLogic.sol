// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {HubSpokeStructs} from "../../../contracts/HubSpokeStructs.sol";

library CommonOptimisticFinalityLogic {
    function creditMissingOrConflicting(HubSpokeStructs.Credit memory credit, HubSpokeStructs.Credit storage storedCredit) public view returns (bool) {
        return storedCredit.createdAt == 0 ||
            storedCredit.user != credit.user ||
            storedCredit.token != credit.token ||
            storedCredit.creditedAmount != credit.creditedAmount;
    }

    function getActionDirection(HubSpokeStructs.Action _action) public pure returns (HubSpokeStructs.ActionDirection) {
        if (
            _action == HubSpokeStructs.Action.Withdraw ||
            _action == HubSpokeStructs.Action.WithdrawNative ||
            _action == HubSpokeStructs.Action.Borrow ||
            _action == HubSpokeStructs.Action.BorrowNative
        ) {
            return HubSpokeStructs.ActionDirection.Outbound;
        }
        return HubSpokeStructs.ActionDirection.Inbound;
    }
}