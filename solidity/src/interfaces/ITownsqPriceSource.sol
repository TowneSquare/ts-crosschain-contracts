// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface ITownsqPriceSource {
    error NoPriceForAsset();
    error StalePrice();

    struct Price {
        uint256 price;
        uint256 confidence;
        uint256 precision;
        uint256 updatedAt;
    }

    function getPrice(
        bytes32 _asset,
        uint256 _maxAge
    ) external view returns (Price memory price);

    function priceAvailable(bytes32 _asset) external view returns (bool);

    function outputAsset() external view returns (string memory);
}
