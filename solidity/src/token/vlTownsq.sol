// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TownsqBalancerPoolHelper, IBalancerPoolToken, IERC20} from "./TownsqBalancerPoolHelper.sol";
import {IVlTownsqRewardsDistributor} from "../interfaces/rewards/IVlTownsqRewardsDistributor.sol";

/**
 * @title vlTOWNSQ
 * @dev staking for balancer pool tokens with lock periods
 */
contract vlTOWNSQ is Initializable, OwnableUpgradeable {
    using TownsqBalancerPoolHelper for IBalancerPoolToken;

    uint256 public constant UNSTAKE_COOLDOWN = 3 days;

    enum LockPeriod {
        ONE_MONTH,
        THREE_MONTHS,
        SIX_MONTHS,
        TWELVE_MONTHS
    }

    struct Stake {
        uint256 amount;
        uint256 timestamp;
        LockPeriod lockPeriod;
        uint256 unstakeRequestTimestamp;
    }

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    IBalancerPoolToken public poolToken;
    mapping(address => Stake[]) public stakes;
    uint256 public totalVlPower;
    mapping(address => mapping(uint256 => bool)) public stakeExpirationHandled;
    IVlTownsqRewardsDistributor distributor;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Staked(
        address indexed staker,
        uint256 indexed index,
        uint256 amount,
        LockPeriod lockPeriod
    );
    event Restaked(
        address indexed staker,
        uint256 indexed index,
        uint256 amount,
        LockPeriod lockPeriod
    );
    event UnstakeRequested(address indexed staker, uint256 indexed index);
    event Unstaked(
        address indexed staker,
        uint256 indexed index,
        uint256 amount
    );
    event StakeExpired(
        address indexed staker,
        uint256 indexed index,
        uint256 amount
    );
    event TotalVlPowerChanged(uint256 newTotal);
    event RewardDistributorSet(address distributor);

    error ExpirationAlreadyHandled();
    error StakeNotFound();
    error StakeLocked();
    error CooldownPeriod();
    error InvalidInput();
    error RequestUnstakeNotCalled();

    /**
     * @notice contract constructor; prevent initialize() from being invoked on the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev contract initializer
     * @param _poolToken The pool token address
     */
    function initialize(address _poolToken) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        if (_poolToken == address(0)) {
            revert InvalidInput();
        }
        poolToken = IBalancerPoolToken(_poolToken);
    }

    function setTotalVlPower(uint256 _newTotal) external onlyOwner {
        totalVlPower = _newTotal;
    }

    function setRewardDistributor(
        IVlTownsqRewardsDistributor _distributor
    ) public onlyOwner {
        distributor = _distributor;
        emit RewardDistributorSet(address(distributor));
    }

    /**
     * @dev Allows a user to stake a certain amount of tokens for a specified lock period.
     * @param amount The amount of tokens to stake.
     * @param lockPeriod The lock period for the staked tokens.
     * @param staker the address that we are staking on behalf of
     */
    function stake(
        uint256 amount,
        LockPeriod lockPeriod,
        address staker
    ) public {
        if (amount == 0) {
            revert InvalidInput();
        }

        // stake
        poolToken.transferFrom(msg.sender, address(this), amount);

        _doStake(amount, lockPeriod, staker);
    }

    /**
     * @dev Allows a user to stake a certain amount of tokens for a specified lock period.
     * @param amount The amount of tokens to stake.
     * @param lockPeriod The lock period for the staked tokens.
     */
    function stake(uint256 amount, LockPeriod lockPeriod) external {
        stake(amount, lockPeriod, msg.sender);
    }

    function _doStake(
        uint256 amount,
        LockPeriod lockPeriod,
        address staker
    ) internal {
        stakes[staker].push(Stake(amount, block.timestamp, lockPeriod, 0));
        emit Staked(staker, stakes[staker].length - 1, amount, lockPeriod);

        // mint vlTOWNSQ
        uint256 tokenAmount = amount;
        _mint(staker, tokenAmount);

        handleTotalVlPowerChange(
            getVlPowerOfStake(staker, stakes[staker].length - 1),
            0
        );
        if (address(distributor) != address(0)) {
            distributor.handleVlTownsqStakeChange(staker);
        }
    }

    function zapAndStake(
        uint256 townAmount,
        LockPeriod lockPeriod,
        address staker
    ) public payable {
        if (townAmount == 0 && msg.value == 0) {
            revert InvalidInput();
        }

        getTownsq().transferFrom(msg.sender, address(this), townAmount);

        uint256 receivedBalancerLPTokens = poolToken._joinBalancerPool(
            townAmount,
            msg.value
        );

        _doStake(receivedBalancerLPTokens, lockPeriod, staker);
    }

    function zapAndStake(
        uint256 townAmount,
        LockPeriod lockPeriod
    ) public payable {
        zapAndStake(townAmount, lockPeriod, msg.sender);
    }

    /**
     * @dev Allows a user to request unstaking of their tokens.
     * @param index The index of the stake in the user's stake array.
     */
    function requestUnstake(uint256 index) external {
        Stake storage _stake = stakes[msg.sender][index];
        if (block.timestamp < getStakeExpirationTimestamp(msg.sender, index)) {
            revert StakeLocked();
        }

        if (!stakeExpirationHandled[msg.sender][index]) {
            stakeExpirationHandled[msg.sender][index] = true;
            handleTotalVlPowerChange(0, getVlPowerOfStake(msg.sender, index));
        }

        if (address(distributor) != address(0)) {
            distributor.handleVlTownsqStakeChange(msg.sender);
        }

        _stake.unstakeRequestTimestamp = block.timestamp;
        emit UnstakeRequested(msg.sender, index);
    }

    /**
     * @dev Allows a user to unstake their tokens after the cooldown period.
     * @param index The index of the stake in the user's stake array.
     */
    function unstake(uint256 index) external {
        // unstake
        Stake memory _stake = stakes[msg.sender][index];
        uint256 tokenAmount = _stake.amount;

        if (tokenAmount == 0) {
            revert StakeNotFound();
        }

        if (_stake.unstakeRequestTimestamp == 0) {
            revert RequestUnstakeNotCalled();
        }

        if (
            block.timestamp < _stake.unstakeRequestTimestamp + UNSTAKE_COOLDOWN
        ) {
            revert CooldownPeriod();
        }

        delete stakes[msg.sender][index];
        emit Unstaked(msg.sender, index, tokenAmount);

        // burn vlTOWNSQ
        _burn(msg.sender, tokenAmount);

        poolToken.transfer(msg.sender, tokenAmount);
    }

    /**
     * @dev Allows a user to restake their tokens.
     * @param index The index of the stake in the user's stake array.
     * @param lockPeriod The index of the stake in the user's stake array.
     * @param extraAmount amount of BLP tokens to be added to the existing stake.
     */
    function restake(
        uint256 index,
        LockPeriod lockPeriod,
        uint256 extraAmount,
        bool transferPoolToken
    ) private {
        Stake storage _stake = stakes[msg.sender][index];
        if (_stake.amount == 0) {
            revert StakeNotFound();
        }

        uint256 vlPowerToSubtract = 0;
        if (!stakeExpirationHandled[msg.sender][index]) {
            // the expiration hasn't been handled before so this stake's power is still in the total
            vlPowerToSubtract = getVlPowerOfStake(msg.sender, index);
        }

        // New lock period ends before the old lock period would
        if (
            block.timestamp + getLockPeriod(lockPeriod) <
            getStakeExpirationTimestamp(msg.sender, index)
        ) {
            revert StakeLocked();
        }

        if (extraAmount > 0) {
            // This is required for zap and restake, as there will be no transfer of pool token.
            if (transferPoolToken) {
                poolToken.transferFrom(msg.sender, address(this), extraAmount);
            }

            _stake.amount += extraAmount;
            _mint(msg.sender, extraAmount);
        }

        _stake.timestamp = block.timestamp;
        _stake.unstakeRequestTimestamp = 0;
        _stake.lockPeriod = lockPeriod;
        stakeExpirationHandled[msg.sender][index] = false;

        handleTotalVlPowerChange(
            getVlPowerOfStake(msg.sender, index),
            vlPowerToSubtract
        );
        if (address(distributor) != address(0)) {
            distributor.handleVlTownsqStakeChange(msg.sender);
        }

        emit Restaked(msg.sender, index, _stake.amount, _stake.lockPeriod);
    }

    function restake(
        uint256 index,
        LockPeriod lockPeriod,
        uint256 extraAmount
    ) public {
        restake(index, lockPeriod, extraAmount, true);
    }

    function restake(uint256 index, LockPeriod lockPeriod) public {
        restake(index, lockPeriod, 0);
    }

    function restake(uint256 index) public {
        Stake storage _stake = stakes[msg.sender][index];
        restake(index, _stake.lockPeriod);
    }

    function zapAndRestake(
        uint256 townAmount,
        uint256 index,
        LockPeriod lockPeriod
    ) public payable {
        if (townAmount != 0) {
            getTownsq().transferFrom(msg.sender, address(this), townAmount);
        }

        uint256 receivedBalancerLPTokens = 0;

        if (townAmount != 0 || msg.value != 0) {
            receivedBalancerLPTokens = poolToken._joinBalancerPool(
                townAmount,
                msg.value
            );
        }

        restake(index, lockPeriod, receivedBalancerLPTokens, false);
    }

    function handleExpiredStake(address _user, uint256 _index) public {
        if (
            _index >= stakes[_user].length || stakes[_user][_index].amount == 0
        ) {
            revert StakeNotFound();
        }

        if (block.timestamp < getStakeExpirationTimestamp(_user, _index)) {
            revert StakeLocked();
        }

        if (stakeExpirationHandled[_user][_index]) {
            revert ExpirationAlreadyHandled();
        }

        stakeExpirationHandled[_user][_index] = true;

        handleTotalVlPowerChange(0, getVlPowerOfStake(_user, _index));

        if (address(distributor) != address(0)) {
            distributor.handleVlTownsqStakeChange(_user);
        }

        emit StakeExpired(_user, _index, stakes[_user][_index].amount);
    }

    /**
     * @notice returns the the total vote locked power of a user: staked tokens * lock period multiplier
     * @param owner the address of the user
     * @return power the total vote locked power of the user
     */
    function vlPower(address owner) external view returns (uint256 power) {
        for (uint256 i = 0; i < stakes[owner].length; i++) {
            if (!isStakeExpired(owner, i)) {
                power += getVlPowerOfStake(owner, i);
            }
        }
    }

    /**
     * @dev returns the nominal vlPower of the Stake (even if Stake is expired)
     */
    function getVlPowerOfStake(
        address _staker,
        uint256 _index
    ) public view returns (uint256) {
        Stake storage _stake = stakes[_staker][_index];
        return _stake.amount * getLockPeriodMultiplier(_stake.lockPeriod);
    }

    // no need for the modifier here, because getStakeExpirationTimestamp will check it
    function isStakeExpired(
        address _staker,
        uint256 _stakeId
    ) public view returns (bool) {
        return
            block.timestamp >= getStakeExpirationTimestamp(_staker, _stakeId);
    }

    function getStakeExpirationTimestamp(
        address _staker,
        uint256 _stakeId
    ) public view returns (uint256) {
        Stake storage _stake = stakes[_staker][_stakeId];
        return _stake.timestamp + getLockPeriod(_stake.lockPeriod);
    }

    // INTERNAL FUNCTIONS

    function handleTotalVlPowerChange(
        uint256 addedVlPower,
        uint256 subtractedVlPower
    ) internal {
        if (totalVlPower + addedVlPower < subtractedVlPower) {
            revert InvalidInput();
        }
        totalVlPower = totalVlPower + addedVlPower - subtractedVlPower;
        emit TotalVlPowerChanged(totalVlPower);
    }

    /**
     * @dev Returns the lock period in days based on the provided LockPeriod enum value.
     * @param lockPeriod The period for which the tokens are locked.
     * @return The lock period in days.
     */
    function getLockPeriod(
        LockPeriod lockPeriod
    ) internal pure returns (uint256) {
        if (lockPeriod == LockPeriod.ONE_MONTH) {
            return 30 days;
        } else if (lockPeriod == LockPeriod.THREE_MONTHS) {
            return 90 days;
        } else if (lockPeriod == LockPeriod.SIX_MONTHS) {
            return 180 days;
        }

        return 365 days; // lockPeriod == LockPeriod.TWELVE_MONTHS
    }

    /**
     * @dev Calculates the bonus for locking up tokens for a certain period.
     * @param lockPeriod The period for which the tokens are locked.
     * @return The bonus multiplier for the lock period.
     */
    function getLockPeriodMultiplier(
        LockPeriod lockPeriod
    ) internal pure returns (uint256) {
        if (lockPeriod == LockPeriod.ONE_MONTH) {
            return 2;
        } else if (lockPeriod == LockPeriod.THREE_MONTHS) {
            return 5;
        } else if (lockPeriod == LockPeriod.SIX_MONTHS) {
            return 11;
        }

        return 25; // lockPeriod == LockPeriod.TWELVE_MONTHS
    }

    function getTownsq() public view returns (IERC20) {
        (, , IERC20[] memory tokens, , uint256 townIndex, ) = poolToken
            ._getPoolInfo();
        return tokens[townIndex];
    }

    function _mint(address staker, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[staker] += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

    function _burn(address staker, uint256 amount) internal {
        totalSupply -= amount;
        balanceOf[staker] -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
}
