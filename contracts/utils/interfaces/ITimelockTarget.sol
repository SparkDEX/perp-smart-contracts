// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface ITimelockTarget {
    function setGov(address _gov) external;
    function withdrawToken(address _token, address _account, uint256 _amount) external;
}
