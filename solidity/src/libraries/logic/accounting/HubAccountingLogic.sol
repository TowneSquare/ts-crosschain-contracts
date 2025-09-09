// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "@wormhole/interfaces/IWETH.sol";
import "@wormhole/Utils.sol";

import {IMoneyMarketRewardsDistributor} from "../../../interfaces/rewards/IMoneyMarketRewardsDistributor.sol";
import {IWormholeTunnel} from "../../../interfaces/IWormholeTunnel.sol";
import {ISpoke} from "../../../interfaces/ISpoke.sol";

import {InterestLogic} from "../InterestLogic.sol";
import {ValidationLogic} from "../ValidationLogic.sol";

import {HubSpokeStructs} from "../../../contracts/HubSpokeStructs.sol";
import {HubSpokeEvents} from "../../../contracts/HubSpokeEvents.sol";
import {HubStorage} from "../../../contracts/lendingHub/HubStorage.sol";

library HubAccountingLogic {
    using SafeERC20 for IERC20;
    using ValidationLogic for HubSpokeStructs.HubState;
    using InterestLogic for HubSpokeStructs.HubState;

    error InsufficientFunds();
    error InsufficientMsgValue();
    error InvalidAction();
    error PairingRequestNotFound();
    error SpokeAccountNotFound();
    error TransferFailed();
    error UnregisteredAsset();
    error UnusedParameterMustBeZero();
    error UserIdNotFound();
    error ZeroAddress();

    // events need to be in both library and contract to be picked up
    // see: https://ethereum.stackexchange.com/questions/11137/watching-events-defined-in-libraries
    event AccrualIndexUpdated(bytes32 indexed asset, uint256 deposit, uint256 borrow, uint256 timestamp);
    event Deposit(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalDeposited);
    event Withdraw(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalDeposited);
    event Borrow(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalBorrowed);
    event Repay(address indexed vault, bytes32 indexed asset, uint256 amount, uint256 vaultTotalBorrowed);
    event ReservesWithdrawn(bytes32 indexed asset, uint256 amount, uint16 destinationChain, bytes32 destinationAddress);
    event AccountPairingRequestReceived(uint16 indexed chainId, bytes32 indexed account, bytes32 indexed userId);
    event AccountPaired(uint16 indexed chainId, bytes32 indexed account, bytes32 indexed userId);
    // end events from HubSpokeEvents

    function SPOKE_WITHDRAW_RESERVES_GAS_LIMIT() public pure returns (uint256) {
        return 300_000;
    }

    function requireRegisteredAsset(bytes32 asset) public view {
        if (!HubStorage.getAuxilaryContracts().assetRegistry.assetExists(asset)) {
            revert UnregisteredAsset();
        }
    }

    function getUserId(
        uint16 _chainId,
        bytes32 _senderAddress
    ) public view returns (bytes32) {
        // the user ID is the b32 formatted address on Hub
        if (_chainId == HubStorage.getAuxilaryContracts().wormholeTunnel.chainId()) {
            return _senderAddress;
        }

        bytes32 pairedAccount = HubStorage.getUserIdState().userIds[_chainId][_senderAddress];
        if (pairedAccount != bytes32(0)) {
            return pairedAccount;
        }

        // backward-compatible fallback
        if (isEvmEOA(_chainId, _senderAddress)) {
            // the Hub address is not a contract and sender chain is evm
            // allow sender (x-chain address spoof risk is addressed in protocol disclaimers)
            return _senderAddress;
        }

        return bytes32(0);
    }

    function requireUserId(
        uint16 _chainId,
        bytes32 _senderAddress
    ) public view returns (bytes32 userId) {
        userId = getUserId(_chainId, _senderAddress);
        if (userId == bytes32(0)) {
            revert UserIdNotFound();
        }
    }

    function isEvmEOA(uint16 _chainId, bytes32 _senderAddress) public view returns (bool) {
        return HubStorage.getAuxilaryContracts().wormholeTunnel.isEvm(_chainId) && !isContract(fromWormholeFormat(_senderAddress));
    }

    function isContract(address _addr) public view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_addr)
        }
        return codeSize != 0;
    }

    function getUserAddress(
        bytes32 _userId,
        uint16 _targetChain
    ) public view returns (bytes32) {
        if (_targetChain == HubStorage.getAuxilaryContracts().wormholeTunnel.chainId()) {
            return _userId;
        }

        bytes32 targetAddress = HubStorage.getUserIdState().spokeChainAddresses[_userId][_targetChain];
        if (targetAddress != bytes32(0)) {
            return targetAddress;
        }

        // the target chain is not the Hub and there is no mapping defined
        // check if the main address is a contract
        if (isEvmEOA(_targetChain, _userId)) {
            // the main account is an EOA and is sending to an EVM chain
            // this can be safely allowed
            return _userId;
        }

        return bytes32(0);
    }

    function requireUserAddress(
        bytes32 _userId,
        uint16 _targetChain
    ) public view returns (bytes32) {
        bytes32 addr = getUserAddress(_userId, _targetChain);
        if (addr == bytes32(0)) {
            revert SpokeAccountNotFound();
        }
        return addr;
    }

    function handlePairingRequest(
        uint16 _chainId,
        bytes32 _account,
        bytes32 _userId
    ) public {
        HubStorage.getUserIdState().pairingRequests[_chainId][_account] = _userId;
        emit AccountPairingRequestReceived(_chainId, _account, _userId);
    }

    function confirmPairingRequest(
        uint16 _chainId,
        bytes32 _account,
        bytes32 _userId
    ) public {
        HubSpokeStructs.UserIdState storage userIdState = HubStorage.getUserIdState();
        if (userIdState.pairingRequests[_chainId][_account] != _userId) {
            revert PairingRequestNotFound();
        }

        // if the new account is an EVM address different from userId, any funds belonging to it need to be migrated
        if (_account != _userId && uint256(_account) >> 160 == 0) {
            address userIdAddr = fromWormholeFormat(_userId);
            address newAccountAddr = fromWormholeFormat(_account);

            // migrate funds from account being paired to userId
            bytes32[] memory assets = HubStorage.getAuxilaryContracts().assetRegistry.getRegisteredAssets();
            for (uint256 i = 0; i < assets.length; i++) {
                updateAccrualIndices(assets[i]);
                HubSpokeStructs.DenormalizedVaultAmount memory currentBalance = InterestLogic.getVaultAmounts(userIdAddr, assets[i]);
                HubSpokeStructs.DenormalizedVaultAmount memory newBalance = InterestLogic.getVaultAmounts(newAccountAddr, assets[i]);
                emit Repay(newAccountAddr, assets[i], newBalance.borrowed, 0);
                emit Withdraw(newAccountAddr, assets[i], newBalance.deposited, 0);
                currentBalance.deposited += newBalance.deposited;
                currentBalance.borrowed += newBalance.borrowed;
                emit Deposit(userIdAddr, assets[i], newBalance.deposited, currentBalance.deposited);
                emit Borrow(userIdAddr, assets[i], newBalance.borrowed, currentBalance.borrowed);
                newBalance.deposited = 0;
                newBalance.borrowed = 0;
                setVaultAmounts(userIdAddr, assets[i], currentBalance);
                setVaultAmounts(newAccountAddr, assets[i], newBalance);
            }
        }

        delete userIdState.pairingRequests[_chainId][_account];

        userIdState.spokeChainAddresses[_userId][_chainId] = _account;
        userIdState.userIds[_chainId][_account] = _userId;

        emit AccountPaired(_chainId, _account, _userId);
    }

    function accountForUserAction(
        bytes32 userId,
        HubSpokeStructs.Action action,
        bytes32 asset,
        uint256 amount
    ) public {
        // TODO: re-index all based on bytes32 addressing
        address user = fromWormholeFormat(userId);

        updateAccrualIndices(asset);

        if (action == HubSpokeStructs.Action.Withdraw || action == HubSpokeStructs.Action.WithdrawNative) {
            ValidationLogic.checkAllowedToWithdraw(user, asset, amount);
        } else if (action == HubSpokeStructs.Action.Borrow || action == HubSpokeStructs.Action.BorrowNative) {
            ValidationLogic.checkAllowedToBorrow(user, asset, amount);
        } else if (action == HubSpokeStructs.Action.Repay) {
            ValidationLogic.checkAllowedToRepay(user, asset, amount);
        } else if (action == HubSpokeStructs.Action.Deposit) {
            ValidationLogic.checkAllowedToDeposit(asset, amount);
        } else {
            revert InvalidAction();
        }

        updateVaultAmounts(action, user, asset, amount);
    }

    /**
     * @dev Assets accrue interest over time, so at any given point in time the value of an asset is (amount of asset on day 1) * (the amount of interest that has accrued).
     * This function updates both the deposit and borrow interest accrual indices of the asset.
     *
     * @param assetId - The asset to update the interest accrual indices of
     */
    function updateAccrualIndices(
        bytes32 assetId
    ) public {
        HubSpokeStructs.AssetState storage assetState = HubStorage.getAssetState(assetId);
        assetState.indices = InterestLogic.getCurrentAccrualIndices(assetId);
        assetState.lastActivityBlockTimestamp = block.timestamp;
        emit AccrualIndexUpdated(assetId, assetState.indices.deposited, assetState.indices.borrowed, block.timestamp);
    }

    /**
     * @dev Updates the vault's state to log either a deposit, borrow, withdraw, or repay
     *
     * @param action - the action (either Deposit, Borrow, Withdraw, or Repay)
     * @param vault - the address of the vault
     * @param asset - the ID of the relevant asset being logged
     * @param amount - the amount of the asset assetAddress being logged
     */
    function updateVaultAmounts(
        HubSpokeStructs.Action action,
        address vault,
        bytes32 asset,
        uint256 amount
    ) public {
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmounts = InterestLogic.getVaultAmounts(vault, asset);
        HubSpokeStructs.DenormalizedVaultAmount memory globalAmounts = InterestLogic.getGlobalAmounts(asset);

        if (action == HubSpokeStructs.Action.Deposit) {
            vaultAmounts.deposited += amount;
            globalAmounts.deposited += amount;

            emit Deposit(vault, asset, amount, vaultAmounts.deposited);
        } else if (action == HubSpokeStructs.Action.Withdraw || action == HubSpokeStructs.Action.WithdrawNative) {
            vaultAmounts.deposited -= amount;
            globalAmounts.deposited -= amount;

            emit Withdraw(vault, asset, amount, vaultAmounts.deposited);
        } else if (action == HubSpokeStructs.Action.Borrow || action == HubSpokeStructs.Action.BorrowNative) {
            vaultAmounts.borrowed += amount;
            globalAmounts.borrowed += amount;

            emit Borrow(vault, asset, amount, vaultAmounts.borrowed);
        } else if (action == HubSpokeStructs.Action.Repay) {
            if (amount > vaultAmounts.borrowed) {
                // account any over-repayments as a deposit
                uint256 surplus = amount - vaultAmounts.borrowed;
                vaultAmounts.deposited += surplus;
                globalAmounts.deposited += surplus;

                emit Deposit(vault, asset, surplus, vaultAmounts.deposited);

                amount = vaultAmounts.borrowed;
            }
            vaultAmounts.borrowed -= amount;
            globalAmounts.borrowed -= amount;

            emit Repay(vault, asset, amount, vaultAmounts.borrowed);
        } else {
            revert InvalidAction();
        }

        setVaultAmounts(vault, asset, vaultAmounts);
        setGlobalAmounts(asset, globalAmounts);
    }

    function setVaultAmounts(
        address vaultOwner,
        bytes32 asset,
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount
    ) public {
        HubSpokeStructs.StoredVaultAmount storage vault = HubStorage.getAssetState(asset).userVaults[vaultOwner];
        vault.amounts = vaultAmount;
        vault.accrualIndices = InterestLogic.getCurrentAccrualIndices(asset);

        IMoneyMarketRewardsDistributor rewardDistributor = HubStorage.getAuxilaryContracts().rewardDistributor;
        if (address(rewardDistributor) != address(0)) {
            rewardDistributor.handleBalanceChange(vaultOwner, asset);
        }
    }

    function setGlobalAmounts(
        bytes32 asset,
        HubSpokeStructs.DenormalizedVaultAmount memory vaultAmount
    ) public {
        HubSpokeStructs.StoredVaultAmount storage totals = HubStorage.getAssetState(asset).totals;
        totals.amounts = vaultAmount;
        totals.accrualIndices = InterestLogic.getCurrentAccrualIndices(asset);
    }

    /**
     * @notice Get the protocol's global reserve amount in an asset
     *
     * @param asset - the ID of the asset
     * @return uint256 The amount of the asset in the protocol's reserve
     */
    function getReserveAmount(bytes32 asset) public view returns (uint256) {
        if (asset == bytes32(0)) {
            revert ZeroAddress();
        }
        HubSpokeStructs.DenormalizedVaultAmount memory globalAmounts = InterestLogic.getGlobalAmounts(asset);
        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();
        uint16 thisChainId = auxContracts.wormholeTunnel.chainId();
        address thisChainAsset = fromWormholeFormat(auxContracts.assetRegistry.getAssetAddress(asset, thisChainId));
        uint256 tokenBalance = thisChainAsset == address(0) ? 0 : IERC20(thisChainAsset).balanceOf(address(this));

        uint16[] memory spokeChains = auxContracts.assetRegistry.getSupportedChains();
        uint256 sumOfSpokeBalances = 0;
        // wrapped token balances can be removed once assets are fully migrated to Spokes
        uint256 sumOfWrappedTokenBalances = 0;
        for (uint256 i = 0; i < spokeChains.length; i++) {
            if (spokeChains[i] == thisChainId) {
                // skip Hub chain
                continue;
            }
            bytes32 spokeAssetAddress = auxContracts.assetRegistry.getAssetAddress(asset, spokeChains[i]);
            if (spokeAssetAddress == bytes32(0)) {
                // spoke doesn't support asset
                continue;
            }
            IERC20 wrappedToken = IERC20(auxContracts.wormholeTunnel.getTokenAddressOnThisChain(spokeChains[i], spokeAssetAddress));
            if (address(wrappedToken) != address(0) && address(wrappedToken) != address(auxContracts.wormholeTunnel.USDC())) {
                // WH tunnel maps all CCTP USDC to a single ARB address, so we have to exclude the duplicates
                // ARB USDC is accounted for as Hub chain USDC
                sumOfWrappedTokenBalances += wrappedToken.balanceOf(address(this));
            }

            HubSpokeStructs.SpokeState storage spokeState = HubStorage.getSpokeState(spokeChains[i]);
            sumOfSpokeBalances += spokeState.balances[spokeAssetAddress].finalized + spokeState.balances[spokeAssetAddress].unfinalized;
        }

        // reserves are all that the Hub and Spokes have minus what is owed to users
        // amount owed to users is the sum of deposits minus the sum of borrows
        // reserves = (hubBalance + spokeBalances) - (deposits - borrows) = hubBalance + spokeBalances + borrows - deposits
        return tokenBalance + sumOfWrappedTokenBalances + sumOfSpokeBalances + globalAmounts.borrowed - globalAmounts.deposited;
    }

    /**
     * @notice Withdraws reserves from the contract. If the amount is greater than the reserve balance, then
     * the entire reserve balance is withdrawn.
     * @param assetId: The ID of the asset. Pass bytes32(0) for native asset.
     * @param destinationChain: The chain to withdraw the reserves from
     * @param destinationAddress: The bytes32 address of the withdrawal target
     * @param amount: The amount of the wrapped asset to withdraw
     */
    function withdrawReserves(
        bytes32 assetId,
        uint16 destinationChain,
        bytes32 destinationAddress,
        uint256 amount
    ) public {
        if (destinationAddress == bytes32(0) || destinationChain == 0) {
            revert ZeroAddress();
        }

        uint256 reserveBalance = assetId == bytes32(0) ? address(this).balance : getReserveAmount(assetId);
        // can't withdraw more than reserve balance
        if (amount > reserveBalance) {
            amount = reserveBalance;
        }

        HubSpokeStructs.AuxilaryContracts storage auxContracts = HubStorage.getAuxilaryContracts();

        uint16 hubChainId = auxContracts.wormholeTunnel.chainId();

        if (assetId == bytes32(0)) {
            // withdraw native ETH from Hub
            (bool success,) = payable(fromWormholeFormat(destinationAddress)).call{value: amount}("");
            if (!success) {
                revert TransferFailed();
            }
        } else if (destinationChain == hubChainId) {
            // withdraw native Hub chain token
            IERC20 thisChainAsset = IERC20(fromWormholeFormat(auxContracts.assetRegistry.requireAssetAddress(assetId, hubChainId)));
            thisChainAsset.safeTransfer(fromWormholeFormat(destinationAddress), amount);
        } else {
            // x-chain withdraw
            bytes32 spokeChainAddress = auxContracts.assetRegistry.requireAssetAddress(assetId, destinationChain);
            HubSpokeStructs.SpokeState storage destinationSpokeState = HubStorage.getSpokeState(destinationChain);
            // the Spoke needs to have enough finalized funds for the withdrawal
            // unfinalized funds might not be there anymore
            if (amount > destinationSpokeState.balances[spokeChainAddress].finalized) {
                revert InsufficientFunds();
            }
            // reduce the Spoke finalized funds by the amount withdrawn
            destinationSpokeState.balances[spokeChainAddress].finalized -= amount;

            // send a x-chain withdrawal message
            IWormholeTunnel.TunnelMessage memory message;
            message.source = IWormholeTunnel.MessageSource(
                hubChainId,
                toWormholeFormat(address(this)),
                destinationSpokeState.spoke // send any gas refund to Spoke on target
            );
            message.target = IWormholeTunnel.MessageTarget({
                chainId: destinationChain,
                recipient: destinationSpokeState.spoke,
                selector: ISpoke.releaseFunds.selector,
                payload: abi.encode(HubSpokeStructs.ReleaseFundsPayload({
                    user: destinationAddress,
                    token: spokeChainAddress,
                    amount: amount,
                    nonce: block.timestamp, // this is to prevent a repeat withdrawal in case of a Spoke chain re-delivery
                    unwrapWeth: false
                }))
            });
            message.finality = IWormholeTunnel.MessageFinality.INSTANT;
            uint256 withdrawCost = auxContracts.wormholeTunnel.getMessageCost(destinationChain, SPOKE_WITHDRAW_RESERVES_GAS_LIMIT(), 0, false);
            // it's ok to cover this cost from Hub ETH balance
            if (address(this).balance < withdrawCost) {
                revert InsufficientMsgValue();
            }
            auxContracts.wormholeTunnel.sendEvmMessage{value: withdrawCost}(message, SPOKE_WITHDRAW_RESERVES_GAS_LIMIT());
        }

        emit ReservesWithdrawn(assetId, amount, destinationChain, destinationAddress);
    }
}