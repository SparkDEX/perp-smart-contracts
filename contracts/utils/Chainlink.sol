// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';
import './Governable.sol';

/// @title Chainlink
/// @notice Consumes price data
contract Chainlink is Governable{
    // -- Constants -- //
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant MIN_RATE_STALE_PERIOD = 300; // 5 minutes
    uint256 public constant MAX_RATE_STALE_PERIOD = 86400;  // 1 day

    mapping(bytes20 => uint256) public priceFeedStalePeriod;  

    event PriceFeedStalePeriodUpdated(bytes20 feed, uint256 stalePeriod);

    // -- Errors -- //
    error StaleRate();

    /// @notice Set chainlink price feed stale period
    /// @dev Only callable by governance
    /// @param _priceFeed Price feed address 
    /// @param _stalePeriod Stale Period in seconds
    function setPriceFeedStalePeriod(bytes20 _priceFeed, uint256 _stalePeriod) external onlyGov {
        address priceFeed = address(uint160(_priceFeed));
        require(priceFeed != address(0), '!zero-address');
        require(_stalePeriod >= MIN_RATE_STALE_PERIOD, '!min-stale-period');
        require(_stalePeriod <= MAX_RATE_STALE_PERIOD, '!max-stale-period');
        priceFeedStalePeriod[_priceFeed] = _stalePeriod;
        emit PriceFeedStalePeriodUpdated(_priceFeed, _stalePeriod);
    }


    /// @notice Returns the latest chainlink price
    /// @param _feed address of chainlink pricefeed
    function getPrice(bytes20 _feed) public view returns (uint256) {
        address feed = address(uint160(_feed));
        if (feed == address(0)) return 0;

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);

        (
            uint80 roundId, 
            int price, 
            /*uint startedAt*/,
            uint256 updatedAt, 
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        require(price > 0, "Chainlink price <= 0");
        require(updatedAt != 0, "Incomplete round");
        require(answeredInRound >= roundId, "Stale price");
        uint256 stalePeriod = priceFeedStalePeriod[_feed] > 0 ? priceFeedStalePeriod[_feed] : MAX_RATE_STALE_PERIOD; 

        if (updatedAt < block.timestamp - stalePeriod) {
            revert StaleRate();
        }

        uint8 decimals = priceFeed.decimals();

        // Return 18 decimals standard
        return (uint256(price) * UNIT) / 10 ** decimals;
    }
}
