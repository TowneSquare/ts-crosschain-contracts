// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.20;

import {HubSpokeStructs} from "../HubSpokeStructs.sol";

library HubStorage {
    struct MappedAssetState {
        mapping(bytes32 => HubSpokeStructs.AssetState) assets;
    }

    //keccak256(keccak256("town.hub.AssetState") - 1) && ~0xff
    bytes32 public constant ASSET_STATE_SLOT =
        0x1a2fe6a86eacf37f2abec742ef3af680146b17d55bea4cff5ab8bf0c72ed5a00;

    function getAssetState(
        bytes32 _id
    ) public view returns (HubSpokeStructs.AssetState storage state) {
        MappedAssetState storage mappedState;
        assembly ("memory-safe") {
            mappedState.slot := ASSET_STATE_SLOT
        }
        state = mappedState.assets[_id];
    }

    //keccak256(keccak256("town.hub.AuxilaryContracts") - 1) && ~0xff
    bytes32 public constant AUXILARY_CONTRACTS_SLOT =
        0x2ec9d2b591a445d1d92b44b7857ca628236a22a5c171652e7fe5ca27e3c62700;

    function getAuxilaryContracts()
        public
        pure
        returns (HubSpokeStructs.AuxilaryContracts storage state)
    {
        assembly ("memory-safe") {
            state.slot := AUXILARY_CONTRACTS_SLOT
        }
    }

    struct MappedSpokeState {
        mapping(uint16 => HubSpokeStructs.SpokeState) spokeStates;
    }

    //keccak256(keccak256("town.hub.SpokeState") - 1) && ~0xff
    bytes32 public constant SPOKE_STATE_SLOT =
        0x4811fd213ece5b4175168c72db307d1addea98ab9e72edf711eb47d0de03e800;

    function getSpokeState(
        uint16 _chainId
    ) public view returns (HubSpokeStructs.SpokeState storage state) {
        MappedSpokeState storage mappedState;
        assembly ("memory-safe") {
            mappedState.slot := SPOKE_STATE_SLOT
        }
        state = mappedState.spokeStates[_chainId];
    }

    //keccak256(keccak256("town.hub.UserIdState") - 1) && ~0xff
    bytes32 public constant USER_ID_STATE_SLOT =
        0xa10d2a1a7dde3b23dd63461986c03876f6be2809713c4f26e39bc4a9b0cc3200;

    function getUserIdState()
        public
        pure
        returns (HubSpokeStructs.UserIdState storage state)
    {
        assembly ("memory-safe") {
            state.slot := USER_ID_STATE_SLOT
        }
    }

    //keccak256(keccak256("town.hub.FeesLimitsAndPrecisionsState") - 1) && ~0xff
    bytes32 public constant FEES_LIMITS_AND_PRECISIONS_STATE =
        0xbbd8c734bc31135ca6b84d44487eb127c8c332c8b1d668f5d14e15fb018e2e00;

    function getFeesLimitsAndPrecisionsState()
        internal
        pure
        returns (HubSpokeStructs.FeesLimitsAndPrecisionsState storage state)
    {
        assembly ("memory-safe") {
            state.slot := FEES_LIMITS_AND_PRECISIONS_STATE
        }
    }
}
