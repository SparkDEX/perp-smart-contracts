// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '../utils/Governable.sol';
import './AddressStorage.sol';
import '../Store.sol';
import '../PositionManager.sol';


/// @title TradingValidator
/// @notice Implementation of risk mitigation measures such as maximum open interest and maximum pool drawdown
contract TradingValidator is Governable {
    // Constants
    uint256 public constant BPS_DIVIDER = 10000;

    mapping(bytes10 => mapping(address => uint256)) private maxOI; // market => asset => amount

    // Pool Risk Measures
    uint256 public poolHourlyDecay = 417; // bps  4.17% hourly, disappears after 24 hours
    mapping(address => int256) private poolProfitTracker; // asset => amount (amortized)
    mapping(address => uint256) private poolProfitLimit; // asset => bps
    mapping(address => uint256) private poolLastChecked; // asset => timestamp

    event Link(address store, address positionManager);
    event MaxOISet(address indexed asset, bytes10 indexed market, uint256 amount);
    event PoolHourlyDecaySet(uint256 poolHourlyDecay);
    event PoolProfitLimitSet(address indexed asset, uint256 poolProfitLimit);
 
    // Contracts
    AddressStorage public immutable addressStorage;
    Store public store;
    PositionManager public positionManager;

    /// @dev Only callable by PositionManager contract
    modifier onlyPositionManager() {
        require(msg.sender == address(positionManager), "!unauthorized");
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage) {
        addressStorage = _addressStorage;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        store = Store(addressStorage.getAddress('Store'));
        positionManager = PositionManager(addressStorage.getAddress('PositionManager'));
        emit Link(address(store), address(positionManager));
    }

    /// @notice Set maximum open interest
    /// @notice Once current open interest exceeds this value, orders are no longer accepted
    /// @dev Only callable by governance
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _asset Address of base asset, e.g. address(0) for ETH
    /// @param _amount Max open interest to set
    function setMaxOI(bytes10 _market, address _asset, uint256 _amount) external onlyGov {
        require(_amount > 0, '!amount');
        maxOI[_market][_asset] = _amount;
        emit MaxOISet(_asset, _market, _amount);
    }

    /// @notice Set maximum open interest
    /// @notice Once current open interest exceeds this value, orders are no longer accepted
    /// @dev Only callable by governance
    /// @param _markets Array of Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _assets Array of Address of base asset, e.g. address(0) for ETH
    /// @param _amounts Array of Max open interest to set
    function setMaxOIs(bytes10[] calldata _markets, address[] calldata _assets, uint256[] calldata _amounts) external onlyGov {
        require(_markets.length == _assets.length,"!invalid input");
        require(_markets.length == _amounts.length,"!invalid input");

        for (uint256 i; i < _markets.length; i++) {
            require(_amounts[i] > 0, '!amount');
            maxOI[_markets[i]][_assets[i]] = _amounts[i];
            emit MaxOISet(_assets[i], _markets[i], _amounts[i]);            
        }    

    }

    /// @notice Set hourly pool decay
    /// @dev Only callable by governance
    /// @param _poolHourlyDecay Hourly pool decay in bps
    function setPoolHourlyDecay(uint256 _poolHourlyDecay) external onlyGov {
        require(_poolHourlyDecay < BPS_DIVIDER, '!poolHourlyDecay');
        poolHourlyDecay = _poolHourlyDecay;
        emit PoolHourlyDecaySet(_poolHourlyDecay);
    }

    /// @notice Set pool profit limit of `asset`
    /// @dev Only callable by governance
    /// @param _asset Address of asset, e.g. address(0) for ETH
    /// @param _poolProfitLimit Pool profit limit in bps
    function setPoolProfitLimit(address _asset, uint256 _poolProfitLimit) external onlyGov {
        require(_poolProfitLimit < BPS_DIVIDER, '!poolProfitLimit');
        poolProfitLimit[_asset] = _poolProfitLimit;
        emit PoolProfitLimitSet(_asset, _poolProfitLimit);
    }

    /// @notice Measures the net loss of a pool over time
    /// @notice Reverts if time-weighted drawdown is higher than the allowed profit limit
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Positions.decreasePosition
    /// @param _asset Address of asset, e.g. address(0) for ETH
    /// @param _pnl Profit Loss amount
    function checkPoolDrawdown(address _asset, int256 _pnl) external onlyPositionManager {
        // Get available amount of `_asset` in the pool (pool balance + buffer balance)
        uint256 poolAvailable = store.getAvailable(_asset);

        // Get profit tracker, _pnl > 0 means trader win
        int256 profitTracker = getPoolProfitTracker(_asset) + _pnl;
        // get profit limit of pool
        uint256 profitLimit = poolProfitLimit[_asset];

        // update storage vars
        poolProfitTracker[_asset] = profitTracker;
        poolLastChecked[_asset] = block.timestamp;

        // return if profit limit or profit tracker is zero / less than zero
        if (profitLimit == 0 || profitTracker <= 0) return;

        // revert if profitTracker > profitLimit * available funds
        require(uint256(profitTracker) < (profitLimit * poolAvailable) / BPS_DIVIDER, '!pool-risk');
    }

    /// @notice Checks if maximum open interest is reached
    /// @param _market  Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _asset Address of base asset, e.g. address(0) for ETH
    function checkMaxOI(address _asset, bytes10 _market, uint256 _size) external view {
        uint256 openInterest = positionManager.getOI(_asset, _market);
        uint256 _maxOI = maxOI[_market][_asset];
        if (_maxOI > 0 && openInterest + _size > _maxOI) revert('!max-oi');

        uint256 openAssetInterest = positionManager.getAssetOI(_asset);
        uint256 assetMaxUtilization = store.getAvailableForOI(_asset);
        if (openAssetInterest + _size > assetMaxUtilization) revert('!_asset-max-oi');
    }

    /// @notice Get maximum open interest of `_market`
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _asset Address of base asset, e.g. address(0) for ETH
    function getMaxOI(bytes10 _market, address _asset) external view returns (uint256) {
        return maxOI[_market][_asset];
    }

    /// @notice Returns pool profit tracker of `_asset`
    /// @dev Amortized every hour by 4.16% unless otherwise set
    function getPoolProfitTracker(address _asset) public view returns (int256) {
        int256 profitTracker = poolProfitTracker[_asset];
        uint256 lastCheckedHourId = poolLastChecked[_asset] / (1 hours);
        uint256 currentHourId = block.timestamp / (1 hours);

        if (currentHourId > lastCheckedHourId) {
            // hours passed since last check
            uint256 hoursPassed = currentHourId - lastCheckedHourId;
            if (hoursPassed >= (BPS_DIVIDER + poolHourlyDecay -1) / poolHourlyDecay) {
                profitTracker = 0;
            } else {
                profitTracker = (profitTracker * (int256(BPS_DIVIDER) - int256(poolHourlyDecay) * int256(hoursPassed))) / int256(BPS_DIVIDER);
            }
        }

        return profitTracker;
    }

    /// @notice Returns pool profit limit of `_asset`
    function getPoolProfitLimit(address _asset) external view returns (uint256) {
        return poolProfitLimit[_asset];
    }
}
