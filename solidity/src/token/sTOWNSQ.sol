// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISTownsqRewardsDistributor} from "../interfaces/rewards/ISTownsqRewardsDistributor.sol";

contract sTOWNSQ is ERC20Upgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    

    event Staked(address indexed staker, uint256 amount);
    event UnstakeRequested(
        address indexed staker,
        uint256 amount,
        uint256 unstakeAvailableAt
    );
    event Unstaked(address indexed staker, uint256 amount);
    event RewardDistributorSet(address distributor);
    event UnstakeCooldownSet(uint256 cooldown);

    error CooldownPeriod();
    error InvalidInput();
    error TokenNotTransferable();

    struct UnstakeRequest {
        uint256 amount;
        uint256 unstakeAvailableAt;
    }

    IERC20 public town;
    ISTownsqRewardsDistributor distributor;
    mapping(address => UnstakeRequest) public unstakeRequests;
    uint256 public unstakeCooldown;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _town,
        ISTownsqRewardsDistributor _distributor
    ) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        if (address(_town) == address(0)) {
            revert InvalidInput();
        }
        town = _town;
        setRewardDistributor(_distributor);
        setUnstakeCooldown(3 days);
    }

    //
    // GETTERS
    //

    function balanceOf(
        address _addr
    ) public view virtual override returns (uint256) {
        return super.balanceOf(_addr) - lockedBalanceOf(_addr);
    }

    function lockedBalanceOf(address _addr) public view returns (uint256) {
        return unstakeRequests[_addr].amount;
    }

    function getUnstakeRequest(
        address _addr
    ) public view returns (UnstakeRequest memory) {
        return unstakeRequests[_addr];
    }

    //
    // SETTERS
    //

    function setRewardDistributor(
        ISTownsqRewardsDistributor _distributor
    ) public onlyOwner {
        distributor = _distributor;
        emit RewardDistributorSet(address(distributor));
    }

    function setUnstakeCooldown(uint256 _cooldown) public onlyOwner {
        unstakeCooldown = _cooldown;
        emit UnstakeCooldownSet(unstakeCooldown);
    }

    //
    // INTERACTIONS
    //

    function transfer(
        address,
        uint256
    ) public pure virtual override returns (bool) {
        revert TokenNotTransferable();
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public pure virtual override returns (bool) {
        revert TokenNotTransferable();
    }

    function stake(uint256 _amount) external {
        town.safeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
        emit Staked(msg.sender, _amount);

        if (address(distributor) != address(0)) {
            distributor.handleSTownsqStakeChange(msg.sender);
        }
    }

    function requestUnstake(uint256 _amount) external {
        uint256 balance = balanceOf(msg.sender);
        if (_amount > balance) {
            revert ERC20InsufficientBalance(msg.sender, balance, _amount);
        }

        UnstakeRequest storage request = unstakeRequests[msg.sender];
        request.amount += _amount;
        request.unstakeAvailableAt = block.timestamp + unstakeCooldown;

        // locking more sTOWNSQ into an unstake request changes the staked balance
        // if there's a reward distributor attached it needs to be notified
        if (address(distributor) != address(0)) {
            distributor.handleSTownsqStakeChange(msg.sender);
        }

        emit UnstakeRequested(msg.sender, _amount, request.unstakeAvailableAt);
    }

    function unstake() external {
        UnstakeRequest storage request = unstakeRequests[msg.sender];
        if (
            request.unstakeAvailableAt == 0 ||
            block.timestamp < request.unstakeAvailableAt
        ) {
            revert CooldownPeriod();
        }

        uint256 amount = request.amount;

        request.amount = 0;
        request.unstakeAvailableAt = 0;

        _burn(msg.sender, amount);
        emit Unstaked(msg.sender, amount);

        town.safeTransfer(msg.sender, amount);
    }
}
