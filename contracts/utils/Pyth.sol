// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;
import '@pythnetwork/pyth-sdk-solidity/IPyth.sol';
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import '@openzeppelin/contracts/utils/Address.sol';
import './Governable.sol';
import './AddressStorage.sol';

/// @title Pyth
/// @notice https://docs.pyth.network/
contract Pyth is Governable {

    using Address for address payable;

    // Contracts
    AddressStorage public immutable addressStorage;
    IPyth public pyth;
    address public executorAddress;

    mapping(bytes32 => PythStructs.Price) public pythPrices;


    event Link(address executor, address pyth);
    event UpdatePriceFeeds(bytes32 indexed id,int64 price,uint64 conf,int32 expo,uint256 publishTime);

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
    }

    /// @dev Only callable by Executor contracts
    modifier onlyExecutor() {
        require(msg.sender == executorAddress, "!unauthorized");
        _;
    }    

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        executorAddress = addressStorage.getAddress('Executor');
        pyth = IPyth(addressStorage.getAddress('PythNetwork'));
        emit Link(
            executorAddress,
            address(pyth)
        );
    }

    /// @notice Update pyth prices to pyth or local storage
    /// @param _priceUpdateData Pyth priceUpdateData or PythStructs.price array for local staorage
    function updatePriceFeeds(bytes[] calldata _priceUpdateData) external payable onlyExecutor returns(uint256){
        // updates price for all submitted price feeds
        if(address(pyth) != address(0)){
            uint256 fee = pyth.getUpdateFee(_priceUpdateData);
            require(msg.value >= fee, '!pyth-fee');
            pyth.updatePriceFeeds{value: fee}(_priceUpdateData);
            uint256 diff = msg.value - fee;
            if (diff > 0) {
                payable(msg.sender).sendValue(diff);
            }            
            return diff;
        }else{  //offline pyth price submitted to local storage
            for (uint256 i; i < _priceUpdateData.length; i++) {
                (bytes32 id,int64 price,uint64 conf,int32 expo,uint256 publishTime) = abi.decode(_priceUpdateData[i], (bytes32,int64,uint64,int32,uint256));
                PythStructs.Price memory curPrice = pythPrices[id];
                if(curPrice.publishTime < publishTime){  // update only newer price
                    PythStructs.Price memory pythPrice = PythStructs.Price(
                        price,
                        conf,
                        expo,
                        publishTime
                    );
                    pythPrices[id] = pythPrice;
                    emit UpdatePriceFeeds(id, price, conf, expo, publishTime);

                }

            }
            if (msg.value > 0) {
                payable(msg.sender).sendValue(msg.value);
            }
            return msg.value;
        }
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory price){
        if(address(pyth) != address(0))
            return pyth.getPriceUnsafe(id);
        else    
            return pythPrices[id];
    }
}
