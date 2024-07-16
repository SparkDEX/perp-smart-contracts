//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IPositionManager {
    function setMinPositionHoldTime(uint256 _minPositionHoldTime) external;
    function setRemoveMarginBuffer(uint256 bps) external;
    function setKeeperFeeShare(uint256 bps) external;
    function setTrailingStopFee(uint256 bps) external;
    function setLiquidationFee(uint256 bps) external;   
}
