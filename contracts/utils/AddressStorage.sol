// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '../utils/Governable.sol';
import './interfaces/IAddressStorage.sol';

/// @title AddressStorage
/// @notice General purpose address storage contract
/// @dev Access is restricted to governance
contract AddressStorage is Governable,IAddressStorage {
    mapping(bytes32 => address) public addressValues;

    event AddressSet(string indexed key, address value);
   
    /// @param key The key for the record
    /// @param value address to store
    /// @param overwrite Overwrites existing value if set to true   
    function setAddress(string calldata key, address value, bool overwrite) external override onlyGov returns (bool) {
        require(value != address(0), "!zero address");
        bytes32 hash = getHash(key);
        if (overwrite || addressValues[hash] == address(0)) {
            addressValues[hash] = value;
            emit AddressSet(key, value);
            return true;
        }
        return false;
    }

    
    /// @param key The key for the record
    function getAddress(string calldata key) external view returns (address) {
        return addressValues[getHash(key)];
    }

    /// @param key string to hash
    function getHash(string memory key) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(key));
    }
}
