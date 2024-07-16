//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IExecutor {
    function setLiquidationFee(uint256 bps) external; 
    function setIsReferencePriceMandatory(bool _mandatory) external;  
}
