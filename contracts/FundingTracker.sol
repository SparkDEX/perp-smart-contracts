// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import './utils/AddressStorage.sol';
import './Store.sol';
import './PositionManager.sol';
import './utils/Governable.sol';

/**
 * @title  FundingTracker
 * @notice Funding rates are calculated hourly for each market and collateral
 *         asset based on the real-time open interest imbalance
 */
contract FundingTracker is Governable {

    // Constants
    uint256 public constant UNIT = 10 ** 18;

    // interval used to calculate accrued funding
    uint256 public fundingInterval = 1 hours;

    // asset => market => funding tracker (long) (short is opposite)
    mapping(address => mapping(bytes10 => int256)) private fundingTrackers;

    // asset => market => last time fundingTracker was updated. In seconds.
    mapping(address => mapping(bytes10 => uint256)) private lastUpdated;


    // Events
    event FundingUpdated(address indexed asset, bytes10 market, int256 fundingTracker, int256 fundingIncrement);
    event FundingIntervalUpdated(uint256 interval);
    event Link(address store, address positionManager, address executor);


    // Contracts
    AddressStorage public immutable addressStorage;
    Store public store;
    PositionManager public positionManager;
    address public executorAddress;

    /// @dev Only callable by PositionManager or Executor contracts
    modifier onlyPositionManagerAndExecutor() {
        require(msg.sender == address(positionManager) || msg.sender == executorAddress, "!unauthorized");
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage) {
        addressStorage = _addressStorage;
    }

    /// @notice Set Funding Interval
    /// @dev Only callable by governance
    /// @param _interval Funding Interval
    function setFundingInterval(uint256 _interval) external onlyGov {
        require(_interval > 0, '!interval');
        fundingInterval = _interval;
        emit FundingIntervalUpdated(_interval);
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        store = Store(addressStorage.getAddress('Store'));
        positionManager = PositionManager(addressStorage.getAddress('PositionManager'));
        executorAddress = addressStorage.getAddress('Executor');
        emit Link(
            address(store),
            address(positionManager),
            executorAddress
        );
    }

    /// @notice Returns last update timestamp of `asset` and `market`
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function getLastUpdated(address _asset, bytes10 _market) external view returns (uint256) {
        return lastUpdated[_asset][_market];
    }

    /// @notice Returns funding tracker of `asset` and `market`
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function getFundingTracker(address _asset, bytes10 _market) external view returns (int256) {
        return fundingTrackers[_asset][_market];
    }

    /// @notice Returns funding tracker of `asset` and `market` includes unrealized funding trackers
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function getNextFundingTracker(address _asset, bytes10 _market) external view returns (int256) {
        int256 fundingTracker = fundingTrackers[_asset][_market];    
        if(lastUpdated[_asset][_market]+fundingInterval <= block.timestamp){
            int256 fundingIncrement = getAccruedFunding(_asset, _market, 0); // in UNIT * bps
            if (fundingIncrement != 0){
                fundingTracker += fundingIncrement;
            }
        }
        return fundingTracker;
    }

    /// @notice Returns funding trackers of `assets` and `markets`
    /// @param _assets Array of asset addresses
    /// @param _markets Array of market bytes10s
    function getFundingTrackers(
        address[] calldata _assets,
        bytes10[] calldata _markets
    ) external view returns (int256[] memory fts) {
        uint256 assetLength = _assets.length;
        uint256 marketLength = _markets.length;
        fts = new int256[](assetLength * marketLength);
        uint index;
        for (uint256 i; i < assetLength; i++) {
             for (uint256 j; j < marketLength; j++) {
                index = (i * marketLength) + j;
                fts[index] = fundingTrackers[_assets[i]][_markets[j]];
            }
        }
        return fts;
    }

    /// @notice Returns funding trackers of `assets` and `markets` includes unrealized funding trackers
    /// @param _assets Array of asset addresses
    /// @param _markets Array of market bytes10s
    function getNextFundingTrackers(
        address[] calldata _assets,
        bytes10[] calldata _markets
    ) external view returns (int256[] memory fts) {
        uint256 assetLength = _assets.length;
        uint256 marketLength = _markets.length;
        fts = new int256[](assetLength * marketLength);
        uint index;
        for (uint256 i; i < assetLength; i++) {
             for (uint256 j; j < marketLength; j++) {
                index = (i * marketLength) + j;
                fts[index] = fundingTrackers[_assets[i]][_markets[j]];
                if(lastUpdated[_assets[i]][_markets[j]]+fundingInterval <= block.timestamp){
                    int256 fundingIncrement = getAccruedFunding(_assets[i], _markets[j], 0); // in UNIT * bps
                    if (fundingIncrement != 0){
                        fts[index] += fundingIncrement;
                    }
                }
            }
        }
        return fts;
    }


    /// @notice Updates funding tracker of `market` and `asset`
    /// @dev Only callable by position manager or executor contracts
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function updateFundingTracker(address _asset, bytes10 _market) external onlyPositionManagerAndExecutor {
        uint256 _lastUpdated = lastUpdated[_asset][_market];
        uint256 _now = block.timestamp;

        // condition is true only on the very first execution
        if (_lastUpdated == 0) {
            lastUpdated[_asset][_market] = _now;
            return;
        }

        // returns if block.timestamp - lastUpdated is less than funding interval
        if (_lastUpdated + fundingInterval > _now) return;

        // positive funding increment indicates that shorts pay longs, negative that longs pay shorts
        int256 fundingIncrement = getAccruedFunding(_asset, _market, 0); // in UNIT * bps

        lastUpdated[_asset][_market] = _now;

        // return if funding increment is zero
        if (fundingIncrement == 0) return;

        fundingTrackers[_asset][_market] += fundingIncrement;

        emit FundingUpdated(_asset, _market, fundingTrackers[_asset][_market], fundingIncrement);
    }

    /// @notice Returns accrued funding of `market` and `asset`
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD"
    /// @param _intervals intervals , if 0, it is calculated from the last updated point until now,if fundingInterval is 3600,then 1 for 1h ,24 for 1 day 
    function getAccruedFunding(address _asset, bytes10 _market, uint256 _intervals) public view returns (int256) {
        if (_intervals == 0) {
            _intervals = (block.timestamp - lastUpdated[_asset][_market]) / fundingInterval;
        }

        if (_intervals == 0) return 0;

        uint256 OILong = positionManager.getOILong(_asset, _market);
        uint256 OIShort = positionManager.getOIShort(_asset, _market);

        if (OIShort == 0 && OILong == 0) return 0;

        uint256 OIDiff = OIShort > OILong ? OIShort - OILong : OILong - OIShort;

        Store.Market memory marketInfo = store.getMarket(_market);
        uint256 yearlyFundingFactor = marketInfo.fundingFactor;


        uint256 accruedFunding = (UNIT * yearlyFundingFactor * OIDiff * _intervals) / ((365 days / fundingInterval) * (OILong + OIShort)); // in UNIT * bps

        if (OILong > OIShort) {
            // Longs pay shorts. Increase funding tracker.
            return int256(accruedFunding);
        } else {
            // Shorts pay longs. Decrease funding tracker.
            return -1 * int256(accruedFunding);
        }
    }
}
