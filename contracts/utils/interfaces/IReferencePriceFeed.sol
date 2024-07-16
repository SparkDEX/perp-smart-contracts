// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IReferencePriceFeed {
    function getPrice(bytes20 _priceFeedOrSymbol) external view returns (uint256);
    function setPriceFeedStalePeriod(bytes20 _priceFeedOrSymbol, uint256 _stalePeriod) external;
}
