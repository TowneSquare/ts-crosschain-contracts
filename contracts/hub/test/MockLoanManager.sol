// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "../interfaces/IHubPool.sol";
import "../interfaces/ILoanManager.sol";

contract MockLoanManager is ILoanManager {
    event Deposit(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount);
    event DepositTsToken(bytes32 loanId, bytes32 accountId, uint8 poolId, address sender, uint256 fAmount);
    event Withdraw(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount, bool isFAmount);
    event WithdrawTsToken(bytes32 loanId, bytes32 accountId, uint8 poolId, address recipient, uint256 fAmount);
    event Borrow(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount, uint256 maxStableRate);
    event Repay(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount, uint256 maxOverRepayment);
    event RepayWithCollateral(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount);
    event Liquidate(
        bytes32 violatorLoanId,
        bytes32 liquidatorLoanId,
        bytes32 liquidatorAccountId,
        uint8 colPoolId,
        uint8 borPoolId,
        uint256 maxRepayAmount,
        uint256 minSeizedAmount
    );
    event SwitchBorrowType(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 maxStableRate);
    event RebalanceUp(bytes32 loanId, uint8 poolId);
    event RebalanceDown(bytes32 loanId, uint8 poolId);

    bytes32 public constant override HUB_ROLE = keccak256("HUB");
    bytes32 public constant override REBALANCER_ROLE = keccak256("REBALANCER");

    mapping(uint8 poolId => IHubPool) private _pools;
    uint256 private _depositUnderlyingAmount = 0;

    function setPool(uint8 poolId, IHubPool pool) external {
        _pools[poolId] = pool;
    }

    function setDepositUnderlyingAmount(uint256 newDepositUnderlyingAmount) external {
        _depositUnderlyingAmount = newDepositUnderlyingAmount;
    }

    function getPool(uint8 poolId) external view override returns (IHubPool) {
        return _pools[poolId];
    }

    function createUserLoan(
        bytes4 nonce,
        bytes32 accountId,
        uint16 loanTypeId,
        bytes32 loanName
    ) external override returns (bytes32 loanId) {
        emit CreateUserLoan(nonce, accountId, loanTypeId, loanName);
        loanId = nonce;
    }

    function deleteUserLoan(bytes32 loanId, bytes32 accountId) external override {
        emit DeleteUserLoan(loanId, accountId);
    }

    function deposit(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount) external {
        emit Deposit(loanId, accountId, poolId, amount);
    }

    function depositTsToken(
        bytes32 loanId,
        bytes32 accountId,
        uint8 poolId,
        address sender,
        uint256 fAmount
    ) external override {
        emit DepositTsToken(loanId, accountId, poolId, sender, fAmount);
    }

    function withdraw(
        bytes32 loanId,
        bytes32 accountId,
        uint8 poolId,
        uint256 amount,
        bool isFAmount
    ) external override returns (uint256 underlingAmount) {
        underlingAmount = _depositUnderlyingAmount;
        emit Withdraw(loanId, accountId, poolId, amount, isFAmount);
    }

    function withdrawTsToken(
        bytes32 loanId,
        bytes32 accountId,
        uint8 poolId,
        address recipient,
        uint256 fAmount
    ) external override {
        emit WithdrawTsToken(loanId, accountId, poolId, recipient, fAmount);
    }

    function borrow(
        bytes32 loanId,
        bytes32 accountId,
        uint8 poolId,
        uint256 amount,
        uint256 maxStableRate
    ) external override {
        emit Borrow(loanId, accountId, poolId, amount, maxStableRate);
    }

    function repay(
        bytes32 loanId,
        bytes32 accountId,
        uint8 poolId,
        uint256 amount,
        uint256 maxOverRepayment
    ) external override {
        emit Repay(loanId, accountId, poolId, amount, maxOverRepayment);
    }

    function repayWithCollateral(bytes32 loanId, bytes32 accountId, uint8 poolId, uint256 amount) external override {
        emit RepayWithCollateral(loanId, accountId, poolId, amount);
    }

    function liquidate(
        bytes32 violatorLoanId,
        bytes32 liquidatorLoanId,
        bytes32 liquidatorAccountId,
        uint8 colPoolId,
        uint8 borPoolId,
        uint256 maxRepayAmount,
        uint256 minSeizedAmount
    ) external override {
        emit Liquidate(
            violatorLoanId,
            liquidatorLoanId,
            liquidatorAccountId,
            colPoolId,
            borPoolId,
            maxRepayAmount,
            minSeizedAmount
        );
    }

    function switchBorrowType(
        bytes32 loanId,
        bytes32 accountId,
        uint8 poolId,
        uint256 maxStableRate
    ) external override {
        emit SwitchBorrowType(loanId, accountId, poolId, maxStableRate);
    }

    function rebalanceUp(bytes32 loanId, uint8 poolId) external override {
        emit RebalanceUp(loanId, poolId);
    }

    function rebalanceDown(bytes32 loanId, uint8 poolId) external override {
        emit RebalanceDown(loanId, poolId);
    }
}
