// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import "@api3/contracts/v0.8/interfaces/IProxy.sol";

/// @title Api3
/// @notice Consumes price data
contract Api3{
    // -- Constants -- //
    uint256 public constant RATE_STALE_PERIOD = 86400;


    // -- Errors -- //
    error InvalidPrice();
    error StaleRate();

    /// @notice Returns the latest api3 price
    /// @param _feed address of api3 pricefeed
    function getPrice(bytes20 _feed) public view returns (uint256) {
        address feed = address(uint160(_feed));
        if (feed == address(0)) return 0;

        (int224 price, uint256 timestamp) = IProxy(feed).read();
        if (price <= 0) {
            revert InvalidPrice();
        }

        if (timestamp < block.timestamp - RATE_STALE_PERIOD) {
            revert StaleRate();
        }

        return uint256(uint224(price));
    }
}
