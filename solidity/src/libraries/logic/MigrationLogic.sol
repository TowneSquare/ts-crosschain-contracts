// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {HubStorage} from "../../../src/contracts/lendingHub/HubStorage.sol";
import {HubSpokeStructs} from "../../../src/contracts/HubSpokeStructs.sol";
import {InterestLogic} from "./InterestLogic.sol";
import {HubAccountingLogic} from "./accounting/HubAccountingLogic.sol";
import {IAssetRegistry} from "../../interfaces/IAssetRegistry.sol";
import {IWormholeTunnel} from "../../interfaces/IWormholeTunnel.sol";
import {ILegacyAssetRegistry} from "../../interfaces/ILegacyAssetRegistry.sol";
import {IInterestRateCalculator} from "../../../src/interfaces/IInterestRateCalculator.sol";
import "@wormhole/Utils.sol";

library MigrationLogic {
    event GlobalStateMigrated();
    event UserMigrated(address indexed user);
    event AccrualIndexUpdated(
        address indexed asset,
        uint256 deposit,
        uint256 borrow,
        uint256 timestamp
    );

    struct MigrationState {
        mapping(address => bool) userMigrated;
        bool globalStateMigrated;
    }

    //keccak256(keccak256("town.hub.UserMigrationState-UnifiedLiquidity") - 1) && ~0xff
    bytes32 public constant USER_MIGRATION_STATE_SLOT =
        0xbf2b6c5c3005226d3082a397d2a16c9676ddc7302b7ff337a7c2f2dfdf139a00;

    function getMigrationState()
        public
        pure
        returns (MigrationState storage state)
    {
        assembly ("memory-safe") {
            state.slot := USER_MIGRATION_STATE_SLOT
        }
    }

    function isUserMigrated(address _user) public view returns (bool) {
        return getMigrationState().userMigrated[_user];
    }

    function migrateGlobalState(
        HubSpokeStructs.HubState storage _legacyState
    ) public {
        MigrationState storage migrationState = getMigrationState();
        require(
            !migrationState.globalStateMigrated,
            "migration already completed"
        );
        _migratePrecisionsAndFees(_legacyState);
        IAssetRegistry assetRegistry = HubStorage
            .getAuxilaryContracts()
            .assetRegistry;
        bytes32[] memory assets = assetRegistry.getRegisteredAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            _migrateAsset(_legacyState, assets[i]);
        }
        _migrateSpokeState(_legacyState);
        migrationState.globalStateMigrated = true;

        emit GlobalStateMigrated();
    }

    function _migrateSpokeState(
        HubSpokeStructs.HubState storage _legacyState
    ) internal {
        IAssetRegistry assetRegistry = HubStorage
            .getAuxilaryContracts()
            .assetRegistry;
        uint16[] memory chains = assetRegistry.getSupportedChains();
        bytes32[] memory assets = assetRegistry.getRegisteredAssets();
        // for each spoke chain
        for (uint256 cIdx = 0; cIdx < chains.length; cIdx++) {
            HubSpokeStructs.SpokeState storage legacySpokeState = _legacyState
                ._deprecated_spokeStates[chains[cIdx]];
            HubSpokeStructs.SpokeState storage spokeState = HubStorage
                .getSpokeState(chains[cIdx]);
            spokeState.spoke = legacySpokeState.spoke;
            spokeState.wrappedNativeAsset = legacySpokeState.wrappedNativeAsset;
            for (uint256 aIdx = 0; aIdx < assets.length; aIdx++) {
                bytes32 spokeAddress = assetRegistry.getAssetAddress(
                    assets[aIdx],
                    chains[cIdx]
                );
                if (spokeAddress == bytes32(0)) {
                    // asset not supported on spoke
                    continue;
                }
                spokeState.balances[spokeAddress].finalized += legacySpokeState
                    .balances[spokeAddress]
                    .finalized;
                spokeState
                    .balances[spokeAddress]
                    .unfinalized += legacySpokeState
                    .balances[spokeAddress]
                    .unfinalized;
            }
        }
    }

    function _migratePrecisionsAndFees(
        HubSpokeStructs.HubState storage _legacyState
    ) internal {
        HubSpokeStructs.FeesLimitsAndPrecisionsState storage flp = HubStorage
            .getFeesLimitsAndPrecisionsState();
        flp.interestAccrualIndexPrecision = _legacyState
            ._deprecated_interestAccrualIndexPrecision;
        flp.liquidationFee = _legacyState._deprecated_liquidationFee;
        flp.defaultGasLimit = _legacyState._deprecated_defaultGasLimit;
        flp.refundGasLimit = _legacyState._deprecated_refundGasLimit;
        flp.liquidationFeePrecision = _legacyState
            ._deprecated_liquidationFeePrecision;
    }

    function _migrateAsset(
        HubSpokeStructs.HubState storage _legacyState,
        bytes32 _assetId
    ) internal {
        HubSpokeStructs.DenormalizedVaultAmount memory globals;

        IAssetRegistry assetRegistry = HubStorage
            .getAuxilaryContracts()
            .assetRegistry;
        IWormholeTunnel wormholeTunnel = HubStorage
            .getAuxilaryContracts()
            .wormholeTunnel;
        uint256 indexPrecision = HubStorage
            .getFeesLimitsAndPrecisionsState()
            .interestAccrualIndexPrecision;
        uint16[] memory chains = assetRegistry.getSupportedChains();
        // for each spoke chain
        for (uint256 i = 0; i < chains.length; i++) {
            // get Spoke chain address
            bytes32 spokeAddr = assetRegistry.getAssetAddress(
                _assetId,
                chains[i]
            );
            if (spokeAddr == bytes32(0)) {
                // Spoke doesn't support this asset
                continue;
            }

            if (uint256(spokeAddr) >> 160 != 0) {
                // spoke addr is not EVM compatible
                // this is not an asset that needs to be migrated
                // because no non-EVM assets were supported before
                continue;
            }

            address whWrappedAddress = wormholeTunnel
                .getTokenAddressOnThisChain(chains[i], spokeAddr);
            if (
                chains[i] != wormholeTunnel.chainId() &&
                whWrappedAddress == address(wormholeTunnel.USDC())
            ) {
                // WH tunnel maps all CCTP USDC to a single ARB address, so we have to exclude the duplicates
                continue;
            }

            // get globals from legacy state
            HubSpokeStructs.StoredVaultAmount
                storage legacyGlobals = _legacyState._deprecated_totalAssets[
                    whWrappedAddress
                ];
            // update indices manually through IL.getCurrentAccrualIndices
            _legacyState._deprecated_indices[whWrappedAddress] = InterestLogic
                .getCurrentAccrualIndices(
                    IInterestRateCalculator(
                        _legacyState
                            ._deprecated_assetRegistry
                            .getAssetInfo(whWrappedAddress)
                            .interestRateCalculator
                    ),
                    _legacyState._deprecated_lastActivityBlockTimestamps[
                        whWrappedAddress
                    ],
                    _legacyState._deprecated_totalAssets[whWrappedAddress],
                    _legacyState._deprecated_indices[whWrappedAddress],
                    indexPrecision
                );
            // last old format accrual is emitted to update the subgraph
            emit AccrualIndexUpdated(
                whWrappedAddress,
                _legacyState._deprecated_indices[whWrappedAddress].deposited,
                _legacyState._deprecated_indices[whWrappedAddress].borrowed,
                block.timestamp
            );
            _legacyState._deprecated_lastActivityBlockTimestamps[
                whWrappedAddress
            ] = block.timestamp;
            // update globals manually through IL.applyInterest
            legacyGlobals.amounts = InterestLogic.applyInterest(
                legacyGlobals,
                _legacyState._deprecated_indices[whWrappedAddress]
            );
            legacyGlobals.accrualIndices = _legacyState._deprecated_indices[
                whWrappedAddress
            ];
            // add globals to sums
            globals.deposited += legacyGlobals.amounts.deposited;
            globals.borrowed += legacyGlobals.amounts.borrowed;
        }

        HubSpokeStructs.AssetState storage assetState = HubStorage
            .getAssetState(_assetId);
        assetState.totals.amounts = globals;
        assetState.totals.accrualIndices = HubSpokeStructs.AccrualIndices(
            indexPrecision,
            indexPrecision
        );
        assetState.lastActivityBlockTimestamp = block.timestamp;
    }

    function migrateUser(
        HubSpokeStructs.HubState storage _legacyState,
        address _user
    ) public {
        MigrationState storage migrationState = getMigrationState();
        if (!migrationState.userMigrated[_user]) {
            HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage
                .getAuxilaryContracts();
            uint256 indexPrecision = HubStorage
                .getFeesLimitsAndPrecisionsState()
                .interestAccrualIndexPrecision;
            uint16[] memory chains = auxContracts
                .assetRegistry
                .getSupportedChains();
            bytes32[] memory assets = auxContracts
                .assetRegistry
                .getRegisteredAssets();
            for (uint256 aIdx = 0; aIdx < assets.length; aIdx++) {
                HubSpokeStructs.DenormalizedVaultAmount memory vault;
                // for each spoke chain
                for (uint256 cIdx = 0; cIdx < chains.length; cIdx++) {
                    // get Spoke chain address
                    bytes32 spokeAddr = auxContracts
                        .assetRegistry
                        .getAssetAddress(assets[aIdx], chains[cIdx]);
                    if (spokeAddr == bytes32(0)) {
                        // Spoke doesn't support this asset
                        continue;
                    }

                    if (uint256(spokeAddr) >> 160 != 0) {
                        // spoke addr is not EVM compatible
                        // this is not an asset that needs to be migrated
                        // because no non-EVM assets were supported before
                        continue;
                    }

                    address whWrappedAddress = auxContracts
                        .wormholeTunnel
                        .getTokenAddressOnThisChain(chains[cIdx], spokeAddr);
                    if (
                        chains[cIdx] != auxContracts.wormholeTunnel.chainId() &&
                        address(whWrappedAddress) ==
                        address(auxContracts.wormholeTunnel.USDC())
                    ) {
                        // WH tunnel maps all CCTP USDC to a single ARB address, so we have to exclude the duplicates
                        // ARB USDC is accounted for as Hub chain USDC
                        continue;
                    }

                    // get vault from legacy state
                    HubSpokeStructs.StoredVaultAmount
                        storage legacyVault = _legacyState._deprecated_vault[
                            _user
                        ][whWrappedAddress];
                    if (
                        legacyVault.amounts.deposited == 0 &&
                        legacyVault.amounts.borrowed == 0
                    ) {
                        continue;
                    }
                    // get indices from legacy state (these are already up to date, because of global asset migration)
                    // update vault manually through IL.applyInterest
                    legacyVault.amounts = InterestLogic.applyInterest(
                        legacyVault,
                        _legacyState._deprecated_indices[whWrappedAddress]
                    );
                    // add wrapped vault to new vault
                    legacyVault.accrualIndices = _legacyState
                        ._deprecated_indices[whWrappedAddress];
                    vault.deposited += legacyVault.amounts.deposited;
                    vault.borrowed += legacyVault.amounts.borrowed;
                }

                if (vault.deposited > 0 || vault.borrowed > 0) {
                    // set the combined asset vault with a unit index
                    HubSpokeStructs.StoredVaultAmount
                        storage storedVault = HubStorage
                            .getAssetState(assets[aIdx])
                            .userVaults[_user];
                    storedVault.amounts = vault;
                    storedVault.accrualIndices = HubSpokeStructs.AccrualIndices(
                        indexPrecision,
                        indexPrecision
                    );

                    if (address(auxContracts.rewardDistributor) != address(0)) {
                        // if the user had any shares and a reward distributor is defined
                        auxContracts.rewardDistributor.migrateShares(
                            _user,
                            assets[aIdx]
                        );
                    }
                }
            }

            bytes32 userWhFormat = toWormholeFormat(_user);
            // for each spoke chain
            for (uint256 cIdx = 0; cIdx < chains.length; cIdx++) {
                bytes32 spokeChainAddr = HubAccountingLogic.getUserAddress(
                    userWhFormat,
                    chains[cIdx]
                );
                if (
                    spokeChainAddr == bytes32(0) ||
                    spokeChainAddr == userWhFormat
                ) {
                    continue;
                }
                // migrate OF max nonce
                HubSpokeStructs.SpokeState
                    storage legacySpokeState = _legacyState
                        ._deprecated_spokeStates[chains[cIdx]];
                if (legacySpokeState.maxNonces[spokeChainAddr] > 0) {
                    HubSpokeStructs.SpokeState storage spokeState = HubStorage
                        .getSpokeState(chains[cIdx]);
                    spokeState.maxNonces[spokeChainAddr] = legacySpokeState
                        .maxNonces[spokeChainAddr];
                    HubSpokeStructs.Credit storage _legacyCredit = _legacyState
                        ._deprecated_spokeStates[chains[cIdx]]
                        .credits[spokeChainAddr][
                            spokeState.maxNonces[spokeChainAddr]
                        ];
                    if (
                        _legacyCredit.status !=
                        HubSpokeStructs.CreditStatus.FINALIZED &&
                        _legacyCredit.status !=
                        HubSpokeStructs.CreditStatus.LOST
                    ) {
                        // credit still open. need to copy it into the new storage
                        spokeState.credits[spokeChainAddr][
                            spokeState.maxNonces[spokeChainAddr]
                        ] = _legacyCredit;
                    }
                }
            }

            migrationState.userMigrated[_user] = true;
            emit UserMigrated(_user);
        }
    }
}
