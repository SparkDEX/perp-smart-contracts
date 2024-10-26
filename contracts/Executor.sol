// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';

import './utils/AddressStorage.sol';

import './FundingTracker.sol';
import './OrderBook.sol';
import './Store.sol';
import './PositionManager.sol';
import './utils/FTSOv2.sol';

import './utils/interfaces/IReferencePriceFeed.sol';
import './utils/Governable.sol';

/**
 * @title  Executor
 * @notice Implementation of order execution and position liquidation.
 */
contract Executor is Governable, ReentrancyGuard {
    // Libraries
    using Address for address payable;
    using SafeCast for uint256;

    // Constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_FEE = 500; // 5%

    uint256 public liquidationFee = 25; // 0.25%
    bool isReferencePriceMandatory;
    mapping(address => bool) private whitelistedKeepers;

    // Events
    event LiquidationError(address user, address asset, bytes10 market, uint256 price, string reason);
    event PositionLiquidated(
        address indexed user,
        address indexed asset,
        bytes10 market,
        bool isLong,
        uint96 size,
        uint96 margin,
        uint256 marginUsd,
        uint96 price,
        uint96 fee,
        int256 pnl,
        int256 fundingFee
    );
    event OrderSkipped(uint32 indexed orderId, bytes10 market, uint256 price, uint256 publishTime, string reason);

    event TrailingStopOrderExecuted(       
        address indexed user,
        address indexed asset,
        uint256 indexed orderId,
        bytes10 market,
        uint16 trailingStopPercentage,
        uint96 trailingStopRefPrice,
        uint256 trailingStopRefPriceTimestamp,
        uint256 executionPrice
    );

    event WhitelistedKeeperUpdated(address indexed keeper, bool isActive);
    event LiquidationFeeUpdated(uint256 liquidationFee);
    event ReferencePriceMandatoryUpdated(bool mandatory);
    event Link(address fundingTracker, address store, address orderBook, address positionManager, address referencePriceFeed, address ftsoV2);

    // Contracts
    AddressStorage public immutable addressStorage;
    FundingTracker public fundingTracker;
    OrderBook public orderBook;
    Store public store;
    PositionManager public positionManager;
    IReferencePriceFeed public referencePriceFeed;
    FTSOv2 public ftsoV2;

    /// @dev Reverts if order processing is paused
    modifier ifNotPaused() {
        require(!orderBook.isProcessingPaused(), '!paused');
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
    }

    /// @notice Set Liquidation Fee
    /// @dev Only callable by governance
    /// @param _liquidationFee liquidationFee
    function setLiquidationFee(uint256 _liquidationFee) external onlyGov {
        require(_liquidationFee <= MAX_FEE, '!liquidation-fee');
        liquidationFee = _liquidationFee;
        emit LiquidationFeeUpdated(_liquidationFee);
    }

    /// @notice Set whether reference price is mandatory
    /// @dev Only callable by governance
    /// @param _mandatory boolean
    function setIsReferencePriceMandatory(bool _mandatory) external onlyGov {
        isReferencePriceMandatory = _mandatory;
        emit ReferencePriceMandatoryUpdated(_mandatory);
    }    

    /// @notice Whitelisted keeper that can execute order ,trailing stop order and liquidate position
    /// @dev Only callable by governance
    /// @param _keeper Keeper address
    /// @param _isActive whether keeper is active
    function setWhitelistedKeeper(address _keeper, bool _isActive) external onlyGov {
        whitelistedKeepers[_keeper] = _isActive;
        emit WhitelistedKeeperUpdated(_keeper, _isActive);
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        fundingTracker = FundingTracker(addressStorage.getAddress('FundingTracker'));
        store = Store(payable(addressStorage.getAddress('Store')));
        orderBook = OrderBook(addressStorage.getAddress('OrderBook'));
        positionManager = PositionManager(addressStorage.getAddress('PositionManager'));
        referencePriceFeed = IReferencePriceFeed(addressStorage.getAddress('ReferencePriceFeed'));
        ftsoV2 = FTSOv2(addressStorage.getAddress('FTSOv2'));
        emit Link(
            address(fundingTracker),
            address(store),
            address(orderBook),
            address(positionManager),
            address(referencePriceFeed),
            address(ftsoV2)
        );
    }

    // ORDER EXECUTION

    /// @notice Trailing Stop Order execution by keeper 
    /// @dev Only callable by whitelistedKeepers
    /// @param _orderIds order id's to execute
    /// @param _priceFeedIds different priceFeedIds in orders. e.g if orders's market are BTC,BTC,ETH, pricefeeds should be BTC,ETH for paying lower fee
    /// @param _trailingStopRefPrices Reference Price used to execute for verification
    /// @param _trailingStopRefPriceTimestamps Reference Price timestamp used to execute for verification
    function executeTrailingStopOrders(
        uint32[] calldata _orderIds,
        bytes21[] calldata _priceFeedIds,
        uint96[] calldata _trailingStopRefPrices,
        uint256[] calldata _trailingStopRefPriceTimestamps
    ) external payable nonReentrant ifNotPaused {
        require(whitelistedKeepers[msg.sender], "!unauthorized");
        (uint256[] memory prices, uint64 publishTime, uint256 remainingMsgValue) = ftsoV2.getPrices{value: msg.value}(_priceFeedIds);

        for (uint256 i; i < _orderIds.length; i++) {
            uint32 orderId = _orderIds[i];
            uint96 trailingStopRefPrice = _trailingStopRefPrices[i];
            uint256 trailingStopRefPriceTimestamp = _trailingStopRefPriceTimestamps[i];


            OrderBook.Order memory order = orderBook.get(orderId);

            if(trailingStopRefPrice == 0){
                emit OrderSkipped(orderId, order.market, 0, 0, '!ts-no-ref-price');
                continue;                
            }

            Store.Market memory market = store.getMarket(order.market);

            if (block.timestamp - order.timestamp < market.minOrderAge) {
                // Order too early (front run prevention)
                emit OrderSkipped(orderId, order.market, 0, 0, '!early');
                continue;
            }

            uint256 price = _getMarketPrice(prices, _priceFeedIds, market.priceFeedId, market.priceSpread,order.isLong);

            if (block.timestamp - publishTime > market.priceMaxAge) {
                // Price too old
                emit OrderSkipped(orderId, order.market, price, publishTime, '!stale');
                continue;
            }

            (bool status, string memory reason) = _executeOrder(orderId, price, trailingStopRefPrice, msg.sender);
            if (!status) orderBook.cancelOrder(orderId, reason, msg.sender);

            if (status && bytes(reason).length == 0){
                emit TrailingStopOrderExecuted(order.user, order.asset, orderId, order.market, order.orderDetail.trailingStopPercentage, trailingStopRefPrice, trailingStopRefPriceTimestamp, price);
            }
        }    
        // Refund msg.value excess, if any
        if (remainingMsgValue > 0) {
            payable(msg.sender).sendValue(remainingMsgValue);
        }
    }

    /// @notice Order execution by keeper or orderbook contract for self execution
    /// @dev Only callable by whitelistedKeepers
    /// @param _orderIds order id's to execute
    /// @param _priceFeedIds different priceFeedIds in orders. e.g if orders's market are BTC,BTC,ETH, pricefeeds should be BTC,ETH for paying lower fee
    /// @param _keeper keeper or user address
    function executeOrders(
        uint32[] calldata _orderIds,
        bytes21[] calldata _priceFeedIds,
        address _keeper
    ) external payable nonReentrant ifNotPaused returns (uint256){
        require(whitelistedKeepers[msg.sender] || msg.sender == address(orderBook), "!unauthorized");
        address keeper = msg.sender == address(orderBook) ? _keeper : msg.sender ;
        (uint256[] memory prices, uint64 publishTime, uint256 remainingMsgValue) = ftsoV2.getPrices{value: msg.value}(_priceFeedIds);


        // Get the price for each order
        for (uint256 i; i < _orderIds.length; i++) {
            OrderBook.Order memory order = orderBook.get(_orderIds[i]);
            Store.Market memory market = store.getMarket(order.market);

            if (block.timestamp - order.timestamp < market.minOrderAge) {
                // Order too early (front run prevention)
                emit OrderSkipped(_orderIds[i], order.market, 0, 0, '!early');
                continue;
            }

            uint256 price = _getMarketPrice(prices, _priceFeedIds, market.priceFeedId, market.priceSpread,order.isLong);

            if (block.timestamp - publishTime > market.priceMaxAge) {
                // Price too old
                emit OrderSkipped(_orderIds[i], order.market, price, publishTime, '!stale');
                continue;
            }

            (bool status, string memory reason) = _executeOrder(_orderIds[i], price,0, keeper);
            if (!status){
                if(msg.sender == address(orderBook)){  // if user self execution then revert
                    revert(reason);
                }
                orderBook.cancelOrder(_orderIds[i], reason, keeper);
            }    
        }

        // Refund msg.value excess, if any
        if (remainingMsgValue > 0) {
            payable(msg.sender).sendValue(remainingMsgValue);
        }
        return remainingMsgValue;
    }

    /// @dev Executes submitted order
    /// @param _orderId Order to execute
    /// @param _price market price 
    /// @param _trailingStopRefPrice Reference Price used to execute trailing stop orders for verification
    /// @param _keeper Address of keeper which executes the order
    /// @return status if true, order is not canceled.
    /// @return message if not blank, includes order revert message.
    function _executeOrder(
        uint32 _orderId,
        uint256 _price,
        uint96 _trailingStopRefPrice,
        address _keeper
    ) internal returns (bool, string memory) { 
        OrderBook.Order memory order = orderBook.get(_orderId);

        // Validations

        if (order.size == 0) {
            return (false, '!order');
        }

        if (order.orderDetail.expiry > 0 && order.orderDetail.expiry <= block.timestamp) {
            return (false, '!expired');
        }

        // cancel if order is too old
        // By default, market orders expire after 30 minutes and trigger orders after 180 days
        uint256 ttl = block.timestamp - order.timestamp;
        if ((order.orderDetail.orderType == 0 && ttl > orderBook.maxMarketOrderTTL()) || ttl > orderBook.maxTriggerOrderTTL()) {
            return (false, '!too-old');
        }

        if (_price == 0) {
            return (false, '!no-price');
        }

        Store.Market memory market = store.getMarket(order.market);

        uint256 referencePrice = market.hasReferencePrice ? referencePriceFeed.getPrice(market.priceFeedId) : 0 ;

        // Bound provided price with referencePrice
        if (!_boundPriceWithReferencePrice(market.maxDeviation, referencePrice, _price)) {
            return (true, '!reference-price-deviation'); // returns true so as not to trigger order cancellation
        }

        // Is trigger order executable at provided price?
        if (order.orderDetail.orderType != 0) {
            if (order.orderDetail.orderType == 3) {
                if(order.orderDetail.trailingStopPercentage>0){
                    if(
                        (!order.isLong && _price > (_trailingStopRefPrice * (BPS_DIVIDER - order.orderDetail.trailingStopPercentage)) / BPS_DIVIDER) ||
                        (order.isLong && _price < (_trailingStopRefPrice * (BPS_DIVIDER + order.orderDetail.trailingStopPercentage)) /BPS_DIVIDER)
                    )
                        return (true, '!no-trailing-stop-execution'); // don't cancel order
 
                }else{
                    return (false, '!no-trailing-stop-percentage');  // cancel order
                }

            }else if (
                (order.orderDetail.orderType == 1 && order.isLong && _price > order.orderDetail.price) ||
                (order.orderDetail.orderType == 1 && !order.isLong && _price < order.orderDetail.price) || // limit buy // limit sell
                (order.orderDetail.orderType == 2 && order.isLong && _price < order.orderDetail.price) || // stop buy
                (order.orderDetail.orderType == 2 && !order.isLong && _price > order.orderDetail.price) // stop sell
            ) {
                return (true, '!no-execution'); // don't cancel order
            }
        } else if (order.orderDetail.price > 0) {
            // protected market order (market order with a price). It will execute only if the execution price
            // is better than the submitted price. Otherwise, it will be cancelled
            if ((order.isLong && _price > order.orderDetail.price) || (!order.isLong && _price < order.orderDetail.price)) {
                return (false, '!protected');
            }
        }

        // One-cancels-the-Other (OCO)
        // `cancelOrderId` is an existing order which should be cancelled when the current order executes
        if (order.orderDetail.cancelOrderId > 0) {
            try orderBook.cancelOrder(order.orderDetail.cancelOrderId, '!oco', order.user) {} catch Error(string memory reason) {
                return (false, reason);
            }
        }

        // Check if there is a position
        PositionManager.Position memory position = positionManager.getPosition(order.user, order.asset, order.market);

        bool doAdd = !order.orderDetail.isReduceOnly && (position.size == 0 || order.isLong == position.isLong);
        bool doReduce = position.size > 0 && order.isLong != position.isLong;

        if (doAdd) {
            try positionManager.increasePosition(_orderId, _price, _keeper) {} catch Error(string memory reason) {
                return (false, reason);
            }
        } else if (doReduce) {
            try positionManager.decreasePosition(_orderId, _price, order.orderDetail.orderType == 3, _keeper) {} catch Error(string memory reason) {
                return (false, reason);
            }
        } else {
            return (false, '!reduce');
        }

        return (true, '');
    }

    /// @notice Position liquidation by keeper 
    /// @dev Only callable by whitelistedKeepers
    /// @param _users User addresses to liquidate
    /// @param _assets Base asset array
    /// @param _markets Market array
    /// @param _priceFeedIds different priceFeedIds in orders. e.g if orders's market are BTC,BTC,ETH, pricefeeds should be BTC,ETH for paying lower fee
    function liquidatePositions(
        address[] calldata _users,
        address[] calldata _assets,
        bytes10[] calldata _markets,
        bytes21[] calldata _priceFeedIds
    ) external payable nonReentrant ifNotPaused {
        require(whitelistedKeepers[msg.sender], "!unauthorized");
        (uint256[] memory prices, uint64 publishTime, uint256 remainingMsgValue) = ftsoV2.getPrices{value: msg.value}(_priceFeedIds);

        for (uint256 i; i < _users.length; i++) {
            (bool status, string memory reason, uint256 price) = _liquidatePosition(
                _users[i],
                _assets[i],
                _markets[i],
                prices,
                _priceFeedIds,
                publishTime,
                msg.sender
            );
            if (!status) {
                emit LiquidationError(_users[i], _assets[i], _markets[i], price, reason);
            }
        }

        // Refund msg.value excess, if any
        if (remainingMsgValue > 0) {
            payable(msg.sender).sendValue(remainingMsgValue);
        }
    }

    /// @dev Liquidates position
    /// @param _user User address to liquidate
    /// @param _asset Base asset of position
    /// @param _market Market this position was submitted on
    /// @param _prices prices from FTSOv2
    /// @param _priceFeedIds priceFeedIds
    /// @param _publishTime prices's publishTime
    /// @param _keeper Address of keeper which liquidates position 
    function _liquidatePosition(
        address _user,
        address _asset,
        bytes10 _market,
        uint256[] memory _prices,
        bytes21[] memory _priceFeedIds,
        uint64 _publishTime,
        address _keeper
    ) internal returns (bool, string memory,uint256) {
        PositionManager.Position memory position = positionManager.getPosition(_user, _asset, _market);
        if (position.size == 0) {
            return (false, '!position',0);
        }
        Store.Market memory marketInfo = store.getMarket(_market);

        uint256 price = _getMarketPrice(_prices, _priceFeedIds, marketInfo.priceFeedId, marketInfo.priceSpread,!position.isLong);

        if (block.timestamp - _publishTime > marketInfo.priceMaxAge) {
            return (false, '!stale',price);  //old price 
        }

        if (price == 0) {
            return (false, '!no-price',price);
        }

        uint256 referencePrice = marketInfo.hasReferencePrice ? referencePriceFeed.getPrice(marketInfo.priceFeedId) : 0 ;

        // Bound provided price with referencePrice
        if (!_boundPriceWithReferencePrice(marketInfo.maxDeviation, referencePrice, price)) {
            return (false, '!referencePrice-deviation',price);
        }

        // Get PNL of position
        (int256 pnl, int256 fundingFee) = positionManager.getPnL(
            _asset,
            _market,
            position.isLong,
            price,
            position.price,
            position.size,
            position.fundingTracker
        );

        // Treshold after which position will be liquidated
        uint256 threshold = (position.margin * marketInfo.liqThreshold) / BPS_DIVIDER;

        // Liquidate position if PNL is less than required threshold
        if (pnl <= -1 * int256(threshold)) {            
            uint256 fee = (position.size * (marketInfo.fee + liquidationFee)) / BPS_DIVIDER;

            // Credit trader loss and fee
            store.creditTraderLoss(_user, _asset, _market, position.margin - fee);
            positionManager.creditFee(0, _user, _asset, _market, fee, 0, true, _keeper);

            // Update funding
            // FundingTracker update must be before decrementOI
            fundingTracker.updateFundingTracker(_asset, _market);
            positionManager.decrementOI(_asset, _market, position.size, position.isLong);


            // Remove position
            positionManager.remove(_user, _asset, _market);

            emit PositionLiquidated(
                _user,
                _asset,
                _market,
                position.isLong,
                position.size,
                position.margin,
                _getUsdAmount(_asset, position.margin),
                price.toUint96(),
                fee.toUint96(),
                pnl,
                fundingFee
            );
        }

        return (true, '',price);
    }

    // -- Utils -- //

    /// @dev Returns market price converted to 18 decimals according to market ftsov2 fast update price info
    /// @param _prices prices from FTSOv2
    /// @param _priceFeedIds priceFeedIds   
    /// @param _marketFeedId market's priceFeedId    
    /// @param _priceSpread market's price spread
    /// @param _maximise isMaxPrice?
    /// @return price - Price with 18 decimals
    function _getMarketPrice(
        uint256[] memory _prices, 
        bytes21[] memory _priceFeedIds, 
        bytes21 _marketFeedId, 
        uint16 _priceSpread, 
        bool _maximise
    ) private pure returns(uint256) {
        uint256 price;
        for (uint256 i = 0; i < _priceFeedIds.length; i++) {
            if(_priceFeedIds[i] == _marketFeedId ){
                price = _prices[i];
                break;
            }
        }

        uint256 spread = price * _priceSpread / BPS_DIVIDER;
        if (_maximise) {                
            price = price + spread;
        }else{
            price = price - spread;
        }   
        return price;
    }


    /// @dev Returns USD value of `amount` of `asset`
    /// @dev Used for PositionLiquidated event
    /// @return USD amount with 18 decimals
    function _getUsdAmount(address _asset, uint256 _amount) internal view returns (uint256) {
        Store.Asset memory assetInfo = store.getAsset(_asset);

        try referencePriceFeed.getPrice(assetInfo.priceFeedId) returns(uint256 referencePrice) {
            // _amount is in the asset's decimals, convert to 18. Price is 18 decimals
            return (_amount * referencePrice) / 10 ** assetInfo.decimals;
        } catch { // if price is not valid, dont revert tx.
            return 0;
        }
    }

    /// @dev Fast Update price is bound by the referencePrice 
    /// @return A boolean value indicating whether the price is bounded.
    function _boundPriceWithReferencePrice(
        uint256 _maxDeviation,
        uint256 _referencePrice,
        uint256 _price
    ) internal view returns (bool) {
        if (!isReferencePriceMandatory && (_referencePrice == 0 || _maxDeviation == 0)) return true;
        if (
            _price >= (_referencePrice * (BPS_DIVIDER - _maxDeviation)) / BPS_DIVIDER &&
            _price <= (_referencePrice * (BPS_DIVIDER + _maxDeviation)) / BPS_DIVIDER
        ) {
            return true;
        }
        return false;
    }
}
