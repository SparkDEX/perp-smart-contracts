// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './Governable.sol';

/// @title BatchSender
/// @notice batch sender for using multiple transfer, e.g. referral distribution
/// @dev Access is restricted to whitelisted keepers
contract BatchSender is Governable {
    using SafeERC20 for IERC20;

    mapping(address => bool) private whitelistedKeepers;

    event BatchSend(uint256 indexed typeId, address indexed token, address[] accounts, uint256[] amounts);
    event WhitelistedKeeper(address indexed keeper,bool isActive);

    /// @dev Only callable by whitelisted keepers
    modifier onlyWhitelisted() {
        require(whitelistedKeepers[msg.sender], "BatchSender: forbidden");
        _;
    }

    /// @dev set deployer as whitelisted keeper
    constructor() {
        whitelistedKeepers[msg.sender] = true;
    }

    /// @notice Whitelisted keeper that can send transfer
    /// @dev Only callable by governance
    /// @param keeper Keeper address
    /// @param isActive whether keeper is active
    function setWhitelistedKeeper(address keeper, bool isActive) external onlyGov {
        whitelistedKeepers[keeper] = isActive;
        emit WhitelistedKeeper(keeper, isActive);
    }

    /// @notice send multiple transfer
    /// @dev Only callable by whitelisted keeper
    /// @param _token transfer token
    /// @param _accounts array of accounts
    /// @param _amounts array of amounts
    function send(
        IERC20 _token,
        address[] calldata _accounts,
        uint256[] calldata _amounts
    ) external onlyWhitelisted {
        _send(_token, _accounts, _amounts, 0);
    }

    /// @notice send multiple transfer with specific type id
    /// @dev Only callable by whitelisted keeper
    /// @param _token transfer token
    /// @param _accounts array of accounts
    /// @param _amounts array of amounts
    /// @param _typeId transfer type id
    function sendAndEmit(
        IERC20 _token,
        address[] calldata _accounts,
        uint256[] calldata _amounts,
        uint256 _typeId
    ) external onlyWhitelisted {
        _send(_token, _accounts, _amounts, _typeId);
    }

    /// @notice send multiple transfer with specific type id
    /// @dev Internal function
    /// @param _token transfer token
    /// @param _accounts array of accounts
    /// @param _amounts array of amounts
    /// @param _typeId transfer type id
    function _send(
        IERC20 _token,
        address[] calldata _accounts,
        uint256[] calldata _amounts,
        uint256 _typeId
    ) private {
        for (uint256 i; i < _accounts.length; i++) {
            address account = _accounts[i];
            uint256 amount = _amounts[i];
            _token.transferFrom(msg.sender, account, amount);
        }

        emit BatchSend(_typeId, address(_token), _accounts, _amounts);
    }
}
