//SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;


interface IStore {
    // Structs
    struct Asset {
        uint8 decimals;  
        uint88 minSize;  // minimum position size
        bytes20 referencePriceFeed;  //address or token symbol
    }

    struct Market {
        bytes32 name; // Market's full name, e.g. Bitcoin / U.S. Dollar
        bytes12 category; // crypto, fx, commodities, or indices
        bytes20 referencePriceFeed; // Reference Price feed contract address or token symbol
        bytes32 pythFeed; // Pyth price feed id
        uint16 maxLeverage; // No decimals
        uint16 maxDeviation; // In bps, max price difference from oracle to referencePrice
        uint16 fee; // In bps. 10 = 0.1%
        uint16 liqThreshold; // In bps
        uint16 fundingFactor; // Yearly funding rate if OI is completely skewed to one side. In bps.
        uint8 minOrderAge; // Min order age before is can be executed. In seconds
        uint8 pythMaxAge; // Max Pyth submitted price age, in seconds
        bool isReduceOnly; // accepts only reduce only orders
        uint16 priceConfidenceThresholds;  // in bps. if threshold is higher than pyth price confidence, pyth price is used
        uint16 priceConfidenceMultipliers; // in bps. if threshold is lower than pyth price confidence, pyth price confidence multiplied by multiplier and add or remove pyth price according to min max price
        // e.g pyth price = 1000, pyth confidence = 2 (0.2%), threshold = 10 (0.1%), multiplier= 20000 (200%) => max price = 1000 + (2*2) = 1004, min price = 1000 - (2*2) = 996
    }


    function setAsset(address _asset, Asset memory _assetInfo) external;
    function setMarket(bytes10 _market, Market memory _marketInfo) external;
    function setFeeShare(uint256 _bps) external;
    function setBufferPayoutPeriod(uint256 _period) external;
    function setMaxLiquidityOrderTTL(uint256 _maxLiquidityOrderTTL) external;
    function setUtilizationMultiplier(address _asset, uint256 _utilizationMultiplier) external;
    function withdrawFees(address _asset) external;
    function setIsPublicDeposit(bool _isPublicDeposit) external;
    function setWhitelistedDepositer(address _account, bool _isActive) external;
    function getMarket(bytes10 _market) external view returns (Market memory);
}
