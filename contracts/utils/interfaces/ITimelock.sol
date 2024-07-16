// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

interface ITimelock {
    function setAdmin(address _admin) external;
    function signalSetGov(address _target, address _gov) external;
}
