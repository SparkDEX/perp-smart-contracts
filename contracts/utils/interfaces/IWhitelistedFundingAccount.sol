//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

interface IWhitelistedFundingAccount {
    function setWhitelistedFundingAccount(address account, bool isActive) external;
}
