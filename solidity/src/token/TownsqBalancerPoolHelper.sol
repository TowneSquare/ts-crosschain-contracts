// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {IVault, IWETH} from "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import {IAsset} from "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import {IBasePool} from "@balancer-labs/v2-interfaces/contracts/vault/IBasePool.sol";
import {IBalancerQueries} from "@balancer-labs/v2-interfaces/contracts/standalone-utils/IBalancerQueries.sol";
import {WeightedPoolUserData} from "@balancer-labs/v2-interfaces/contracts/pool-weighted/WeightedPoolUserData.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/helpers/BalancerErrors.sol";

/*
  Balancer does not export a proper interface for the Pool Tokens, so had to hack one.
*/
interface IBalancerPoolToken is IBasePool, IERC20 {
    function getVault() external view returns (IVault);
}

function _asIAsset(
    IERC20[] memory tokens
) pure returns (IAsset[] memory assets) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
        assets := tokens
    }
}

library TownsqBalancerPoolHelper {
    function _getPoolInfo(
        IBalancerPoolToken poolToken
    )
        internal
        view
        returns (
            IVault vault,
            bytes32 poolId,
            IERC20[] memory tokens,
            uint256[] memory balances,
            uint256 townIndex,
            uint256 wethIndex
        )
    {
        vault = poolToken.getVault();
        poolId = poolToken.getPoolId();
        (tokens, , ) = vault.getPoolTokens(poolId);
        require(tokens.length == 2, "Invalid TOWNSQ/WETH balancer pool.");
        (, balances, ) = vault.getPoolTokens(poolId);
        // no need to set the index that's already zero
        if (address(tokens[0]) == address(vault.WETH())) {
            townIndex = 1;
        } else {
            wethIndex = 1;
        }
    }

    function _calculateRequiredETHAmount(
        IBalancerPoolToken poolToken,
        uint256 amountTownsq
    ) internal view returns (uint256) {
        (
            ,
            ,
            ,
            uint256[] memory balances,
            uint256 townIndex,
            uint256 wethIndex
        ) = _getPoolInfo(poolToken);
        return (amountTownsq * balances[wethIndex]) / balances[townIndex];
    }

    function _joinBalancerPool(
        IBalancerPoolToken poolToken,
        uint256 townAmount,
        uint256 ethAmount
    ) internal returns (uint256) {
        (
            IVault vault,
            bytes32 poolId,
            IERC20[] memory tokens,
            ,
            uint256 townIndex,
            uint256 wethIndex
        ) = _getPoolInfo(poolToken);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[townIndex] = townAmount;
        amountsIn[wethIndex] = ethAmount;

        IWETH(address(tokens[wethIndex])).deposit{value: ethAmount}();

        // Use BalancerErrors to validate input
        _require(
            amountsIn.length == tokens.length,
            Errors.INPUT_LENGTH_MISMATCH
        );

        // Encode the userData for a multi-token join
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: _asIAsset(tokens),
            maxAmountsIn: amountsIn,
            // Balancer is the only price source for TOWNSQ
            // and there is no frontrunning on Arbitrum
            // if this contract is ever deployed to a network where this request could be sandwiched
            // then the minimum amount of BPT needs to be added as a parameter and passed instead of zero to userData
            userData: abi.encode(
                WeightedPoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                amountsIn,
                0
            ),
            fromInternalBalance: false
        });

        uint256 balanceLPTokensBefore = poolToken.balanceOf(address(this));

        tokens[townIndex].approve(address(vault), townAmount);
        tokens[wethIndex].approve(address(vault), ethAmount);
        // Call the Vault to join the pool
        vault.joinPool(poolId, address(this), address(this), request);

        uint256 balanceLPTokensDifference = poolToken.balanceOf(address(this)) -
            balanceLPTokensBefore;

        return balanceLPTokensDifference;
    }
}
