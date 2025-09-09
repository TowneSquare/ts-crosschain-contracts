// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IBalancerQueries} from "@balancer-labs/v2-interfaces/contracts/standalone-utils/IBalancerQueries.sol";
import {IrCT} from "./rCT.sol";
import {ITokenConverter} from "./TokenConverter.sol";
import {TownsqBalancerPoolHelper, IBalancerPoolToken, IVault, IWETH} from "./TownsqBalancerPoolHelper.sol";
import {vlTOWNSQ} from "./vlTownsq.sol";

/**
 * @title ItTOWNSQ
 */
interface ItTOWNSQ {
    function mint(address _to, uint256 _amount) external;
}

/**
 * @title tTOWNSQ
 * @dev Staking contract for TOWNSQ. Upon converting NEWO to TOWNSQ, users receive a balance of tTOWNSQ, which can be
 * unstaked for TOWNSQ. Anyone can unstake their tTOWNSQ, but incur a penalty based on a linear formula.
 */
contract tTOWNSQ is ItTOWNSQ, Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using TownsqBalancerPoolHelper for IBalancerPoolToken;

    string public constant name = "Staked TOWNSQ";
    string public constant symbol = "tTOWNSQ";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    address public treasury;
    ITokenConverter public tokenConverter;
    IERC20 public TOWNSQ;
    IrCT public rCT;

    uint256 public stakingPeriodStart;
    uint256 public stakingPeriodEnd;

    vlTOWNSQ public vlTownsq;

    error InvalidInput();
    error OnlyTokenConverter();
    error InsufficientBalance();
    error LockPeriodNotSupported();
    error ETHTransferFailed();
    error InsufficientETHAmount();

    event Transfer(address indexed from, address indexed to, uint256 amount);

    /**
     * @notice contract constructor; prevent initialize() from being invoked on the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev contract initializer
     * @param _tokenConverter The Token Converter contract that can call this contract's `mint()` function
     * @param _TOWNSQ The TOWNSQ token contract
     * @param _treasury The treasury address to receive "burned" TOWNSQ tokens as part of the unstaking penalty
     * @param _rCT Rewards Claim Token
     * @param _stakingPeriodStart When staking period starts (unix timestamp)
     * @param stakingPeriodLength Length of staking period (seconds)
     */
    function initialize(
        address _tokenConverter,
        address _TOWNSQ,
        address _treasury,
        address _rCT,
        uint256 _stakingPeriodStart,
        uint256 stakingPeriodLength,
        address _vlTownsq
    ) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);

        if (
            _tokenConverter == address(0) ||
            _TOWNSQ == address(0) ||
            _treasury == address(0) ||
            _rCT == address(0) ||
            _stakingPeriodStart == 0 ||
            stakingPeriodLength == 0 ||
            _vlTownsq == address(0)
        ) revert InvalidInput();

        treasury = _treasury;
        tokenConverter = ITokenConverter(_tokenConverter);
        TOWNSQ = IERC20(_TOWNSQ);
        rCT = IrCT(_rCT);
        vlTownsq = vlTOWNSQ(_vlTownsq);

        stakingPeriodStart = _stakingPeriodStart;
        stakingPeriodEnd = _stakingPeriodStart + stakingPeriodLength;
    }

    /**
     * @notice Mints tTOWNSQ tokens for `_to`. Only callable by the token converter contract.
     * @param _to Address to receive the tTOWNSQ
     * @param _amount Amount of tTOWNSQ to mint
     */
    function mint(address _to, uint256 _amount) external {
        if (msg.sender != address(tokenConverter)) revert OnlyTokenConverter();

        totalSupply += _amount;
        balanceOf[_to] += _amount;

        emit Transfer(address(0), _to, _amount);
    }

    /**
     * @notice Calculates the penalty (in bps) for unstaking tokens at the currrent block timestamp. The
     * penalty at `stakingPeriodStart` is 9000 bps and decreases linearly until `stakingPeriodEnd`.
     * @return the penalty in bps
     */
    function calculatePenalty() public view returns (uint256) {
        if (block.timestamp >= stakingPeriodEnd) {
            return 0;
        } else {
            uint256 totalDuration = stakingPeriodEnd - stakingPeriodStart;
            uint256 elapsedDuration = block.timestamp - stakingPeriodStart;

            // Calculate the penalty linearly decreasing from 9000 to 0
            return
                ((9000 * (totalDuration - elapsedDuration) * 1e18) /
                    totalDuration) / 1e18;
        }
    }

    /**
     * @notice Allows the caller to unstake their tTOWNSQ to receive TOWNSQ (minus penalty); also burns a portion of the
     * caller's rCT tokens. The penalty amount of TOWNSQ is sent to the `treasury` address.
     * @param _amount The amount of tTOWNSQ to unstake
     */
    function unstake(uint256 _amount) external {
        address sender = msg.sender;

        if (_amount > balanceOf[sender]) revert InsufficientBalance();

        uint256 balanceBefore = balanceOf[sender];

        balanceOf[sender] -= _amount;
        totalSupply -= _amount;

        // calculate the penalty and determine the amount that goes to the treasury
        uint256 penaltyBps = calculatePenalty();
        uint256 penaltyAmount = (_amount * penaltyBps) / 10000;
        uint256 remainingAmount = _amount - penaltyAmount;

        TOWNSQ.safeTransfer(sender, remainingAmount);
        TOWNSQ.safeTransfer(treasury, penaltyAmount);

        _handleRewardsBurning(sender, _amount, balanceBefore);

        emit Transfer(sender, address(0), _amount);
    }

    /**
     * @dev burns a portion of the caller's rCT, if any
     * @param sender the account that is unstaking their tTOWNSQ
     * @param unstakeAmount the amount being unstaked
     * @param balanceBefore the balance in tTownsq before unstaking
     */
    function _handleRewardsBurning(
        address sender,
        uint256 unstakeAmount,
        uint256 balanceBefore
    ) internal {
        if (rCT.balanceOf(sender) == 0) return;

        ITokenConverter.ClaimableRewards memory rewards = tokenConverter
            .rewards(sender);

        // If has more tTOWNSQ than the newoSnapshotBalance, no rCTs are burned
        if (balanceOf[sender] > rewards.totalNewo) return;

        uint256 tTOWNSQBurnedAlongWithRCTs = rewards.burnedTtown;

        // Calculate the amount of tTOWNSQ that can be unstaked without burning any rCTs
        uint256 tTOWNSQToBurnWithoutBurningRCT = balanceBefore +
            tTOWNSQBurnedAlongWithRCTs >
            rewards.totalNewo
            ? balanceBefore + tTOWNSQBurnedAlongWithRCTs - rewards.totalNewo
            : 0;

        // Calculate the amount of tTOWNSQ that is unstaked and also contributes to the rCT burning
        uint256 tTOWNSQToBurnAlongWithRCTs = unstakeAmount >
            tTOWNSQToBurnWithoutBurningRCT
            ? unstakeAmount - tTOWNSQToBurnWithoutBurningRCT
            : 0;

        // Calculate the amount of rCT tokens to burn based on the tTOWNSQToBurnAlongWithRCTs and the conversion rate
        uint256 rctToBurn = (tTOWNSQToBurnAlongWithRCTs * rewards.multiplier) /
            tokenConverter.conversionMultiplierPrecision();

        if (balanceBefore == unstakeAmount) {
            // If the user is unstaking all of their tTOWNSQ, burn all of their rCTs
            // this is to prevent rounding errors introduced by using multipliers
            rctToBurn = rCT.balanceOf(sender);
        }

        rCT.burn(sender, rctToBurn);

        tokenConverter.updateBurned(
            sender,
            rctToBurn,
            tTOWNSQToBurnAlongWithRCTs
        );
    }

    /**
     * @dev returns required amount of ETH to convert to vlTOWNSQ
     */
    function getRequiredETHAmount() public view returns (uint256) {
        uint256 tTownsqAmount = balanceOf[msg.sender];
        return
            IBalancerPoolToken(vlTownsq.poolToken())
                ._calculateRequiredETHAmount(tTownsqAmount);
    }

    /**
     * @dev converts tTOWNSQ to vlTOWNSQ
     * @param lockPeriod lock in vlTOWNSQ
     */
    function convertToVlTownsq(
        vlTOWNSQ.LockPeriod lockPeriod
    ) external payable {
        // 1. Check for acceptable lock periods
        if (
            lockPeriod != vlTOWNSQ.LockPeriod.SIX_MONTHS &&
            lockPeriod != vlTOWNSQ.LockPeriod.TWELVE_MONTHS
        ) {
            revert LockPeriodNotSupported();
        }

        IBalancerPoolToken poolToken = IBalancerPoolToken(vlTownsq.poolToken());

        uint256 tTownsqAmount = balanceOf[msg.sender];

        uint256 requiredETHAmount = getRequiredETHAmount();

        // 2. Check if enough ETH was sent
        if (msg.value < requiredETHAmount) {
            revert InsufficientETHAmount();
        }

        // 3. Join Pool
        uint256 balanceLPTokensDifference = poolToken._joinBalancerPool(
            tTownsqAmount,
            requiredETHAmount
        );

        // 4. Stake Tokens in VLTownsq Pool
        poolToken.approve(address(vlTownsq), balanceLPTokensDifference);
        vlTownsq.stake(balanceLPTokensDifference, lockPeriod, msg.sender);

        // 5. Reduce the tTOWNSQ supply
        balanceOf[msg.sender] -= tTownsqAmount;
        totalSupply -= tTownsqAmount;
        emit Transfer(msg.sender, address(0), tTownsqAmount);

        (bool success, ) = payable(msg.sender).call{
            value: msg.value - requiredETHAmount
        }("");

        if (!success) {
            revert ETHTransferFailed();
        }
    }

    function setVlTOWNSQAddress(address _vlTownsq) public onlyOwner {
        vlTownsq = vlTOWNSQ(_vlTownsq);
    }
}
