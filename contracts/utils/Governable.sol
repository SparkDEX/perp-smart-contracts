// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

/// @title Governable
/// @notice Basic access control mechanism, gov has access to certain functions
contract Governable {
    address public gov;

    event SetGov(address prevGov, address nextGov);

    error NotGovernance(address account);

    /// @dev Initializes the contract setting the deployer address as governance
    constructor() {
        _setGov(msg.sender);
    }

    /// @dev Reverts if called by any account other than gov
    modifier onlyGov() {
        if(msg.sender != gov) 
            revert NotGovernance(msg.sender);
        _;
    }

    /// @notice Sets a new governance address
    /// @dev Only callable by governance
    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "!zero address");
        _setGov(_gov);
    }

    /// @notice Sets a new governance address
    /// @dev Internal function without access restriction
    function _setGov(address _gov) internal {
        address prevGov = gov;
        gov = _gov;
        emit SetGov(prevGov, _gov);
    }
}
