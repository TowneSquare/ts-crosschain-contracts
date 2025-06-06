// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../bridge/interfaces/IBridgeRouter.sol";
import "../../bridge/libraries/Messages.sol";
import "../interfaces/IHubPool.sol";
import "../libraries/DataTypes.sol";

contract MockHubPool is IHubPool, ERC20 {
    event ClearTokenFees(uint256 amount);
    event VerifyReceiveToken(uint16 chainId, bytes32 source);
    event SendTokenMessage(
        IBridgeRouter bridgeRouter,
        uint16 adapterId,
        uint256 gasLimit,
        bytes32 accountId,
        uint16 chainId,
        uint256 amount,
        bytes32 recipient
    );
    event UpdateInterestIndexes();
    event UpdatePoolWithDeposit(uint256 amount);
    event PreparePoolForWithdraw(uint256 amount, bool isFAmount);
    event UpdatePoolWithWithdraw(uint256 underlyingAmount);
    event PreparePoolForWithdrawTsToken();
    event PreparePoolForBorrow(uint256 amount, uint256 maxStableRate);
    event UpdatePoolWithBorrow(
        uint256 oldBorrowAmount,
        uint256 additionalBorrowAmount,
        uint256 oldBorrowStableRate,
        uint256 newBorrowStableRate,
        bool isStable
    );
    event PreparePoolForRepay();
    event UpdatePoolWithRepay(
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 oldLoanBorrowStableRate,
        uint256 excessAmount
    );
    event PreparePoolForRepayWithCollateral();
    event UpdatePoolWithRepayWithCollateral(uint256 principalPaid, uint256 interestPaid, uint256 loanStableRate);
    event UpdatePoolWithLiquidation(
        uint256 repaidBorrowAmount,
        uint256 violatorLoanStableRate,
        uint256 liquidatorOldBorrowAmount,
        uint256 liquidatorOldLoanStableRate,
        uint256 liquidatorNewLoanStableRate
    );
    event PreparePoolForSwitchBorrowType(uint256 amount, uint256 maxStableRate);
    event UpdatePoolWithSwitchBorrowType(uint256 loanBorrowAmount, bool switchingToStable, uint256 loanStableRate);
    event PreparePoolForRebalanceUp();
    event PreparePoolForRebalanceDown();
    event UpdatePoolWithRebalance(uint256 amount, uint256 oldLoanStableInterestRate);
    event MintTsTokenForFeeRecipient(uint256 amount);
    event MintTsToken(address recipient, uint256 amount);
    event BurnTsToken(address sender, uint256 amount);

    error CannotVerifyReceiveToken(uint16 chainId, bytes32 source);

    bytes32 public constant override HUB_ROLE = keccak256("HUB");
    bytes32 public constant override LOAN_MANAGER_ROLE = keccak256("LOAN_MANAGER");

    uint8 private _poolId;
    mapping(uint16 chainId => bytes32 spoke) private _spokes;
    address private _tokenFeeClaimer;
    bytes32 private _tokenFeeRecipientAddress;
    uint256 private _tokenFeeAmount;
    bool private _canVerifyReceiveToken = true;
    Messages.MessageToSend private _sendTokenMessage;
    uint256 private _updatedDepositInterestIndex = 1e18;
    uint256 private _updatedVariableBorrowInterestIndex = 1e18;
    DataTypes.DepositPoolParams private _depositPoolParams;
    DataTypes.WithdrawPoolParams private _withdrawPoolParams;
    DataTypes.BorrowPoolParams private _borrowPoolParams;
    DataTypes.RepayWithCollateralPoolParams private _repayWithCollateralPoolParams;
    DataTypes.RebalanceDownPoolParams private _rebalanceDownPoolParams;

    constructor(string memory tsTokenName, string memory tsTokenSymbol, uint8 poolId_) ERC20(tsTokenName, tsTokenSymbol) {
        _poolId = poolId_;
    }

    function setSpoke(uint16 chainId, bytes32 spoke) external {
        _spokes[chainId] = spoke;
    }

    function setTokenFeeClaimer(address newTokenFeeClaimer) external {
        _tokenFeeClaimer = newTokenFeeClaimer;
    }

    function setTokenFeeRecipient(bytes32 recipient) external {
        _tokenFeeRecipientAddress = recipient;
    }

    function setTokenFeeAmount(uint256 newTokenFeeAmount) external {
        _tokenFeeAmount = newTokenFeeAmount;
    }

    function setCanVerifyReceiveToken(bool newCanVerifyReceiveToken) external {
        _canVerifyReceiveToken = newCanVerifyReceiveToken;
    }

    function setSendTokenMessage(Messages.MessageToSend calldata message) external {
        _sendTokenMessage = message;
    }

    function setUpdatedDepositInterestIndex(uint256 newUpdatedDepositInterestIndex) external {
        _updatedDepositInterestIndex = newUpdatedDepositInterestIndex;
    }

    function setUpdatedVariableBorrowInterestIndex(uint256 newUpdatedVariableBorrowInterestIndex) external {
        _updatedVariableBorrowInterestIndex = newUpdatedVariableBorrowInterestIndex;
    }

    function setDepositPoolParams(DataTypes.DepositPoolParams memory newDepositPoolParams) external {
        _depositPoolParams = newDepositPoolParams;
    }

    function setWithdrawPoolParams(DataTypes.WithdrawPoolParams memory newWithdrawPoolParams) external {
        _withdrawPoolParams = newWithdrawPoolParams;
    }

    function setBorrowPoolParams(DataTypes.BorrowPoolParams memory newBorrowPoolParams) external {
        _borrowPoolParams = newBorrowPoolParams;
    }

    function setRepayWithCollateralPoolParams(
        DataTypes.RepayWithCollateralPoolParams memory newRepayWithCollateralPoolParams
    ) external {
        _repayWithCollateralPoolParams = newRepayWithCollateralPoolParams;
    }

    function setRebalanceDownPoolParams(DataTypes.RebalanceDownPoolParams memory newRebalanceDownPoolParams) external {
        _rebalanceDownPoolParams = newRebalanceDownPoolParams;
    }

    function getPoolId() external view override returns (uint8) {
        return _poolId;
    }

    function getTokenFeeClaimer() external view override returns (address) {
        return _tokenFeeClaimer;
    }

    function getTokenFeeRecipient() external view override returns (bytes32) {
        return _tokenFeeRecipientAddress;
    }

    function clearTokenFees() external override returns (uint256) {
        emit ClearTokenFees(_tokenFeeAmount);
        return _tokenFeeAmount;
    }

    function verifyReceiveToken(uint16 chainId, bytes32 source) external view override {
        if (!_canVerifyReceiveToken) revert CannotVerifyReceiveToken(chainId, source);
    }

    function getSendTokenMessage(
        IBridgeRouter bridgeRouter,
        uint16 adapterId,
        uint256 gasLimit,
        bytes32 accountId,
        uint16 chainId,
        uint256 amount,
        bytes32 recipient
    ) external override returns (Messages.MessageToSend memory) {
        emit SendTokenMessage(bridgeRouter, adapterId, gasLimit, accountId, chainId, amount, recipient);
        return _sendTokenMessage;
    }

    function getUpdatedDepositInterestIndex() external view override returns (uint256) {
        return _updatedDepositInterestIndex;
    }

    function getUpdatedVariableBorrowInterestIndex() external view override returns (uint256) {
        return _updatedVariableBorrowInterestIndex;
    }

    function updateInterestIndexes() external override {
        emit UpdateInterestIndexes();
    }

    function updatePoolWithDeposit(uint256 amount) external override returns (DataTypes.DepositPoolParams memory) {
        emit UpdatePoolWithDeposit(amount);
        return _depositPoolParams;
    }

    function preparePoolForWithdraw(
        uint256 amount,
        bool isFAmount
    ) external override returns (DataTypes.WithdrawPoolParams memory) {
        emit PreparePoolForWithdraw(amount, isFAmount);
        return _withdrawPoolParams;
    }

    function updatePoolWithWithdraw(uint256 underlyingAmount) external override {
        emit UpdatePoolWithWithdraw(underlyingAmount);
    }

    function preparePoolForWithdrawTsToken() external override {
        emit PreparePoolForWithdrawTsToken();
    }

    function preparePoolForBorrow(
        uint256 amount,
        uint256 maxStableRate
    ) external override returns (DataTypes.BorrowPoolParams memory) {
        emit PreparePoolForBorrow(amount, maxStableRate);
        return _borrowPoolParams;
    }

    function updatePoolWithBorrow(
        uint256 oldBorrowAmount,
        uint256 additionalBorrowAmount,
        uint256 oldBorrowStableRate,
        uint256 newBorrowStableRate,
        bool isStable
    ) external override {
        emit UpdatePoolWithBorrow(
            oldBorrowAmount,
            additionalBorrowAmount,
            oldBorrowStableRate,
            newBorrowStableRate,
            isStable
        );
    }

    function preparePoolForRepay() external returns (DataTypes.BorrowPoolParams memory) {
        emit PreparePoolForRepay();
        return _borrowPoolParams;
    }

    function updatePoolWithRepay(
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 oldLoanBorrowStableRate,
        uint256 excessAmount
    ) external override {
        emit UpdatePoolWithRepay(principalPaid, interestPaid, oldLoanBorrowStableRate, excessAmount);
    }

    function updatePoolWithRepayWithCollateral(
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 loanStableRate
    ) external override returns (DataTypes.RepayWithCollateralPoolParams memory) {
        emit UpdatePoolWithRepayWithCollateral(principalPaid, interestPaid, loanStableRate);
        return _repayWithCollateralPoolParams;
    }

    function updatePoolWithLiquidation(
        uint256 repaidBorrowAmount,
        uint256 violatorLoanStableRate,
        uint256 liquidatorOldBorrowAmount,
        uint256 liquidatorOldLoanStableRate,
        uint256 liquidatorNewLoanStableRate
    ) external override {
        emit UpdatePoolWithLiquidation(
            repaidBorrowAmount,
            violatorLoanStableRate,
            liquidatorOldBorrowAmount,
            liquidatorOldLoanStableRate,
            liquidatorNewLoanStableRate
        );
    }

    function preparePoolForSwitchBorrowType(
        uint256 amount,
        uint256 maxStableRate
    ) external override returns (DataTypes.BorrowPoolParams memory) {
        emit PreparePoolForSwitchBorrowType(amount, maxStableRate);
        return _borrowPoolParams;
    }

    function updatePoolWithSwitchBorrowType(
        uint256 loanBorrowAmount,
        bool switchingToStable,
        uint256 loanStableRate
    ) external override {
        emit UpdatePoolWithSwitchBorrowType(loanBorrowAmount, switchingToStable, loanStableRate);
    }

    function preparePoolForRebalanceUp() external override returns (DataTypes.BorrowPoolParams memory) {
        emit PreparePoolForRebalanceUp();
        return _borrowPoolParams;
    }

    function preparePoolForRebalanceDown() external override returns (DataTypes.RebalanceDownPoolParams memory) {
        emit PreparePoolForRebalanceDown();
        return _rebalanceDownPoolParams;
    }

    function updatePoolWithRebalance(uint256 amount, uint256 oldLoanStableInterestRate) external override {
        emit UpdatePoolWithRebalance(amount, oldLoanStableInterestRate);
    }

    function mintTsTokenForFeeRecipient(uint256 amount) external override {
        emit MintTsTokenForFeeRecipient(amount);
    }

    function mintTsToken(address recipient, uint256 amount) external override {
        emit MintTsToken(recipient, amount);
    }

    function burnTsToken(address sender, uint256 amount) external override {
        emit BurnTsToken(sender, amount);
    }
}
