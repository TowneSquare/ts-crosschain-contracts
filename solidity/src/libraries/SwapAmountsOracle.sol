// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import {ITownsqPriceOracle} from "../interfaces/ITownsqPriceOracle.sol";

library SwapAmountsOracle {
    function getOutputForInput(
        ITownsqPriceOracle oracle,
        bytes32 input,
        uint8 inputDecimals,
        bytes32 output,
        uint8 outputDecimals,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        require(
            oracle.priceAvailable(input),
            "input asset unsupported by price oracle"
        );
        require(
            oracle.priceAvailable(output),
            "output asset unsupported by price oracle"
        );
        ITownsqPriceOracle.Price memory inputPrice = oracle.getPrice(input);
        ITownsqPriceOracle.Price memory outputPrice = oracle.getPrice(output);
        if (inputDecimals < outputDecimals) {
            uint256 precisionAdjust = 10 ** (outputDecimals - inputDecimals);
            // 1e18        1e6      1e18               1e12               1e18                      1e18                 1e18
            amountOut =
                (amountIn *
                    inputPrice.price *
                    precisionAdjust *
                    outputPrice.precision) /
                (outputPrice.price * inputPrice.precision);
        } else {
            uint256 precisionAdjust = 10 ** (inputDecimals - outputDecimals);
            // 1e6      1e18        1e18               1e18                        1e18                  1e18               1e12
            amountOut =
                (amountIn * inputPrice.price * outputPrice.precision) /
                (outputPrice.price * inputPrice.precision * precisionAdjust);
        }
    }

    function getInputForOutput(
        ITownsqPriceOracle oracle,
        bytes32 input,
        uint8 inputDecimals,
        bytes32 output,
        uint8 outputDecimals,
        uint256 amountOut
    ) internal view returns (uint256 amountIn) {
        require(
            oracle.priceAvailable(input),
            "input asset unsupported by price oracle"
        );
        require(
            oracle.priceAvailable(output),
            "output asset unsupported by price oracle"
        );
        ITownsqPriceOracle.Price memory inputPrice = oracle.getPrice(input);
        ITownsqPriceOracle.Price memory outputPrice = oracle.getPrice(output);
        if (inputDecimals < outputDecimals) {
            uint256 precisionAdjust = 10 ** (outputDecimals - inputDecimals);
            // 1e6        1e18      1e18                 1e18                      1e18                1e12               1e18
            amountIn =
                (amountOut * outputPrice.price * inputPrice.precision) /
                (inputPrice.price * precisionAdjust * outputPrice.precision);
        } else {
            uint256 precisionAdjust = 10 ** (inputDecimals - outputDecimals);
            // 1e18     1e6        1e18                1e12               1e18                         1e18           1e18
            amountIn =
                (amountOut *
                    outputPrice.price *
                    precisionAdjust *
                    inputPrice.precision) /
                (inputPrice.price * outputPrice.precision);
        }
    }
}
