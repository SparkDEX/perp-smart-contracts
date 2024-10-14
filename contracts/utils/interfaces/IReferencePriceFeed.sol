// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IReferencePriceFeed {
    function getPrice(bytes21 _feedId) external view returns (uint256);
    function setPriceFeedStalePeriod(bytes21 _feedId, uint256 _stalePeriod) external;
}
