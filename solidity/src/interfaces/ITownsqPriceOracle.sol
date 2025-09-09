// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ITownsqPriceSource} from "./ITownsqPriceSource.sol";

interface ITownsqPriceOracle is ITownsqPriceSource {
    struct PriceSource {
        ITownsqPriceSource priceSource;
        uint256 maxPriceAge;
    }

    function sequencerUptimeFeed()
        external
        view
        returns (AggregatorV3Interface);

    function sequencerGracePeriod() external view returns (uint256);

    function getPrice(
        bytes32 _asset
    ) external view returns (Price memory price);

    function setPriceSource(
        bytes32 _asset,
        PriceSource memory _priceSource
    ) external;

    function removePriceSource(bytes32 _asset) external;

    function getPriceSource(
        bytes32 _asset
    ) external view returns (PriceSource memory);
}
