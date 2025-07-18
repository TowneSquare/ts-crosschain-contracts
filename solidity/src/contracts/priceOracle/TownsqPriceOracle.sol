// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseTownsqPriceSource} from "./BaseTownsqPriceSource.sol";
import {ITownsqPriceOracle, ITownsqPriceSource, AggregatorV3Interface} from "../../interfaces/ITownsqPriceOracle.sol";

/**
 * @title TownsqPriceOracle
 */
contract TownsqPriceOracle is ITownsqPriceOracle, BaseTownsqPriceSource {
    mapping(bytes32 => PriceSource) public sources;
    AggregatorV3Interface public override sequencerUptimeFeed;
    uint256 public override sequencerGracePeriod;

    error InvalidAsset();
    error InvalidPriceSource();
    error InvalidMaxPriceAge();
    error InvalidSequencerFeed();
    error InvalidGracePeriod();
    error SequencerDown();

    event PriceSourceSet(
        bytes32 indexed asset,
        ITownsqPriceSource priceSource,
        uint256 maxPriceAge
    );
    event SequencerUptimeFeedSet(
        address indexed sequencerUptimeFeed,
        uint256 gracePeriod
    );

    constructor(
        string memory _outputAsset,
        AggregatorV3Interface _sequencerUptimeFeed,
        uint256 _sequencerGracePeriod
    ) BaseTownsqPriceSource(_outputAsset) {
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    function priceAvailable(
        bytes32 _asset
    ) public view override returns (bool) {
        return sources[_asset].priceSource != ITownsqPriceSource(address(0));
    }

    function getPrice(
        bytes32 _asset
    ) public view override returns (ITownsqPriceOracle.Price memory price) {
        return getPrice(_asset, sources[_asset].maxPriceAge);
    }

    function getPrice(
        bytes32 _asset,
        uint256 _maxAge
    ) public view override returns (ITownsqPriceOracle.Price memory price) {
        if (!priceAvailable(_asset)) {
            revert InvalidPriceSource();
        }

        if (!_sequencerUpAndGracePeriodPassed()) {
            revert SequencerDown();
        }

        return sources[_asset].priceSource.getPrice(_asset, _maxAge);
    }

    function setSequencerUptimeFeed(
        AggregatorV3Interface _feed,
        uint256 _gracePeriod
    ) public onlyOwner {
        if (address(_feed) == address(0)) {
            revert InvalidSequencerFeed();
        }

        if (_gracePeriod == 0) {
            revert InvalidGracePeriod();
        }

        sequencerUptimeFeed = _feed;
        sequencerGracePeriod = _gracePeriod;
        emit SequencerUptimeFeedSet(address(_feed), _gracePeriod);
    }

    /**
     * @notice Checks the sequencer oracle is healthy: is up and grace period passed.
     * @return True if the SequencerOracle is up and the grace period passed, false otherwise
     */
    function _sequencerUpAndGracePeriodPassed() internal view returns (bool) {
        (, int256 answer, uint256 startedAt, , ) = sequencerUptimeFeed
            .latestRoundData();
        // zero means the sequencer is up. there is a grace period that needs to elapse before we start accepting prices again - for things to stabilize.
        // it also allows users to repay any underwater loans that have become liquidatable during the outage
        // see https://docs.chain.link/data-feeds/l2-sequencer-feeds for more info
        return
            answer == 0 && block.timestamp - startedAt > sequencerGracePeriod;
    }

    function setPriceSource(
        bytes32 _asset,
        PriceSource memory _priceSource
    ) external override onlyOwner {
        if (_asset == bytes32(0)) {
            revert InvalidAsset();
        }
        if (_priceSource.priceSource == ITownsqPriceSource(address(0))) {
            revert InvalidPriceSource();
        }
        if (_priceSource.maxPriceAge == 0) {
            revert InvalidMaxPriceAge();
        }
        if (
            keccak256(
                abi.encodePacked(_priceSource.priceSource.outputAsset())
            ) != keccak256(abi.encodePacked(outputAsset))
        ) {
            revert InvalidPriceSource();
        }
        sources[_asset] = _priceSource;

        emit PriceSourceSet(
            _asset,
            _priceSource.priceSource,
            _priceSource.maxPriceAge
        );
    }

    function removePriceSource(bytes32 _asset) external onlyOwner {
        if (sources[_asset].priceSource == ITownsqPriceSource(address(0))) {
            revert InvalidPriceSource();
        }
        delete sources[_asset];
        emit PriceSourceSet(_asset, ITownsqPriceSource(address(0)), 0);
    }

    function getPriceSource(
        bytes32 _asset
    ) external view override returns (PriceSource memory) {
        if (sources[_asset].priceSource == ITownsqPriceSource(address(0))) {
            revert InvalidAsset();
        }
        return sources[_asset];
    }
}
