// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';


import './utils/AddressStorage.sol';
import './utils/TradingValidator.sol';


import './FundingTracker.sol';
import './Store.sol';
import './OrderBook.sol';
import './utils/interfaces/IStore.sol';


import './utils/interfaces/IReferencePriceFeed.sol';
import './interfaces/IReferralStorage.sol';
import './utils/Governable.sol';

/**
 * @title  PositionManager
 * @notice Implementation of position related logic, i.e. increase positions,
 *         decrease positions, close positions, add/remove margin
 */
contract PositionManager is Governable {

    // Constants
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant BPS_DIVIDER = 10000;

        // Libraries
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeCast for uint256;

    // Position struct
    struct Position {
        address user; // User that submitted the position
        bytes10 market; // Market this position was submitted on
        bool isLong; // Whether the position is long or short
        address asset; // Asset address, e.g. address(0) for ETH
        uint96 size; // The position's size (margin * leverage)
        uint32 timestamp; // Time at which the position was created
        uint96 margin; // Collateral tied to this position. In wei
        uint96 price; // The position's average execution price
        int256 fundingTracker; // Market funding rate tracker
    }

    struct OpenInterest {
        uint128 long; 
        uint128 short; 
    }

    // Constants
    uint256 public constant MAX_KEEPER_FEE_SHARE = 2000; // 20%
    uint256 public constant MAX_FEE = 500; // 5%
    uint256 public constant MAX_MIN_POSITION_HOLD_TIME = 1800; // 30 min.
    
    // State variables
    uint256 public removeMarginBuffer = 1000;
    uint256 public keeperFeeShare = 500;
    uint256 public trailingStopFee = 100; // 1%
    uint256 public minPositionHoldTime;

    // Mappings
    mapping(address => OpenInterest) private assetOI; // open interest. asset => OpenInterest

    mapping(address => mapping(bytes10 => OpenInterest)) private OI; // open interest. market => asset => OpenInterest

    mapping(bytes32 => Position) private positions; // key = asset,user,market
    EnumerableSet.Bytes32Set private positionKeys; // [position keys..]
    mapping(address => EnumerableSet.Bytes32Set) private positionKeysForUser; // user => [position keys..]
    // user => market => last position increase
    mapping(address => mapping(bytes10 => uint256)) private lastIncreased;

    // Contracts
    AddressStorage public immutable addressStorage;
    OrderBook public orderBook;
    TradingValidator public tradingValidator;
    IReferralStorage public referralStorage;
    FundingTracker public fundingTracker;
    Store public store;
    IReferencePriceFeed public referencePriceFeed;
    address public executorAddress;

    // Events
    event PositionIncreased(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        bytes10 market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 positionMargin,
        uint256 positionSize,
        uint256 positionPrice,
        int256 fundingTracker,
        uint256 fee
    );

    event PositionDecreased(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        bytes10 market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 positionMargin,
        uint256 positionSize,
        uint256 positionPrice,
        int256 fundingTracker,
        uint256 fee,
        int256 pnl,
        int256 pnlUsd,
        int256 fundingFee,
        bool isTrailingStop
    );

    event MarginIncreased(
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 marginDiff,
        uint256 positionMargin
    );

    event MarginDecreased(
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 marginDiff,
        uint256 positionMargin
    );

    event FeePaid(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 fee,
        uint256 poolFee,
        uint256 treasuryFee,
        uint256 keeperFee,
        uint256 executionFee,
        bool isLiquidation
    );

    event IncreasePositionReferral(
        address indexed account,
        address indexed asset,
        uint256 sizeDelta,
        uint256 fee,
        bytes32 referralCode,
        address referrer
    );

    event DecreasePositionReferral(
        address indexed account,
        address indexed asset,
        uint256 sizeDelta,
        uint256 fee,
        bytes32 referralCode,
        address referrer
    );

    event MinPositionHoldTimeUpdated(uint256 minPositionHoldTime);
    event RemoveMarginBufferUpdated(uint256 bps);
    event KeeperFeeShareUpdated(uint256 keeperFeeShare);
    event TrailingStopFeeUpdated(uint256 trailingStopFee);
    event Link(address orderBook, address tradingValidator, address fundingTracker, address store, address referencePriceFeed, address referralStorage, address executorAddress);
    event RemovePosition(address indexed user, address indexed asset, bytes10 indexed market);
    event IncrementOI(address indexed asset, bytes10 indexed market, uint96 amount, bool isLong);
    event DecrementOI(address indexed asset, bytes10 indexed market, uint96 amount, bool isLong);

    /// @dev Reverts if order processing is paused
    modifier ifNotPaused() {
        require(!orderBook.areNewOrdersPaused(), '!paused');
        _;
    }

    /// @dev Only callable by Executor contract
    modifier onlyExecutor() {
        require(msg.sender == executorAddress, "!unauthorized");
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        orderBook = OrderBook(addressStorage.getAddress('OrderBook'));
        tradingValidator = TradingValidator(addressStorage.getAddress('TradingValidator'));
        fundingTracker = FundingTracker(addressStorage.getAddress('FundingTracker'));
        store = Store(addressStorage.getAddress('Store'));
        referencePriceFeed = IReferencePriceFeed(addressStorage.getAddress('ReferencePriceFeed'));
        referralStorage = IReferralStorage(addressStorage.getAddress('ReferralStorage'));
        executorAddress = addressStorage.getAddress('Executor');
        emit Link(
            address(orderBook), 
            address(tradingValidator), 
            address(fundingTracker), 
            address(store), 
            address(referencePriceFeed), 
            address(referralStorage), 
            executorAddress
        );
    }
    
    /// @notice Set minimum position hold time
    /// @dev Only callable by governance
    /// @param _minPositionHoldTime  minimum position hold time in seconds
    function setMinPositionHoldTime(uint256 _minPositionHoldTime) external onlyGov {
        require(_minPositionHoldTime <= MAX_MIN_POSITION_HOLD_TIME, '!min-position-hold-time');
        minPositionHoldTime = _minPositionHoldTime;
        emit MinPositionHoldTimeUpdated(_minPositionHoldTime);
    }

    /// @notice Updates `removeMarginBuffer`
    /// @dev Only callable by governance
    /// @param _bps new `removeMarginBuffer` in bps
    function setRemoveMarginBuffer(uint256 _bps) external onlyGov {
        require(_bps < BPS_DIVIDER, '!bps');
        removeMarginBuffer = _bps;
        emit RemoveMarginBufferUpdated(_bps);
    }

    /// @notice Sets keeper fee share
    /// @dev Only callable by governance
    /// @param _keeperFeeShare new `keeperFeeShare` in bps
    function setKeeperFeeShare(uint256 _keeperFeeShare) external onlyGov {
        require(_keeperFeeShare <= MAX_KEEPER_FEE_SHARE, '!keeper-fee-share');
        keeperFeeShare = _keeperFeeShare;
        emit KeeperFeeShareUpdated(_keeperFeeShare);
    }

    /// @notice Sets trailing stop fee
    /// @dev Only callable by governance
    /// @dev Only applies if position closed by trailing stop order keeper
    /// @param _trailingStopFee new `trailingStopFee` in bps
    function setTrailingStopFee(uint256 _trailingStopFee) external onlyGov {
        require(_trailingStopFee <= MAX_FEE, '!trailing-stop-fee');
        trailingStopFee = _trailingStopFee;
        emit TrailingStopFeeUpdated(_trailingStopFee);
    }

    /// @notice Opens a new position or increases existing one
    /// @dev Only callable by Executor contract
    function increasePosition(uint32 _orderId, uint256 _price, address _keeper) external onlyExecutor {
        _increasePosition(_orderId,_price,_keeper);
    }

    /// @notice Opens a new position or increases existing one
    /// @dev Internal function invoked by {increasePosition,_decreasePosition}
    function _increasePosition(uint32 _orderId, uint256 _price, address _keeper) internal {
        OrderBook.Order memory order = orderBook.get(_orderId);

        // Check if maximum open interest is reached
        tradingValidator.checkMaxOI(order.asset, order.market, order.size);
        // FundingTracker update must be before increment
        fundingTracker.updateFundingTracker(order.asset, order.market);
        _incrementOI(order.asset, order.market, order.size, order.isLong);


        Position memory position = getPosition(order.user, order.asset, order.market);
        uint96 averagePrice = ((uint256(position.size) * position.price + order.size * _price) / (position.size + order.size)).toUint96();

        // Populate position fields if new position
        if (position.size == 0) {
            position.user = order.user;
            position.asset = order.asset;
            position.market = order.market;
            position.timestamp = block.timestamp.toUint32();
            position.isLong = order.isLong;
            position.fundingTracker = fundingTracker.getFundingTracker(order.asset, order.market);
        }

        // Add or update position
        position.size += order.size;
        position.margin += order.margin;
        position.price = averagePrice;

        _addOrUpdate(position);

        // Remove order
        orderBook.remove(_orderId);

        // Credit fee to _keeper, pool, stakers, treasury
        _creditFee(_orderId, order.user, order.asset, order.market, order.fee, order.orderDetail.executionFee, false, _keeper);

        lastIncreased[order.user][order.market] = block.timestamp;

        emit PositionIncreased(
            _orderId,
            order.user,
            order.asset,
            order.market,
            order.isLong,
            order.size,
            order.margin,
            _price,
            position.margin,
            position.size,
            position.price,
            position.fundingTracker,
            order.fee
        );

        _emitIncreasePositionReferral(order.user, order.asset, order.size, order.fee);
    }

    /// @notice Decreases or closes an existing position
    /// @dev Only callable by Executor contract
    function decreasePosition(uint32 _orderId, uint256 price, bool _isTrailingStop, address _keeper) external onlyExecutor {
        _decreasePosition(_orderId, price, _isTrailingStop, _keeper);
    }    

    /// @notice Decreases or closes an existing position
    /// @dev Internal function invoked by {decreasePosition}
    function _decreasePosition(uint32 _orderId, uint256 price, bool _isTrailingStop, address _keeper) internal {
        OrderBook.Order memory order = orderBook.get(_orderId);
        Position memory position = getPosition(order.user, order.asset, order.market);

        // Check last increased
        require(lastIncreased[order.user][order.market] < block.timestamp - minPositionHoldTime, "!min-hold-time");

        // If position size is less than order size, not all will be executed
        uint256 executedOrderSize = position.size > order.size ? order.size : position.size;
        uint256 remainingOrderSize = order.size - executedOrderSize;

        uint256 remainingOrderMargin;
        uint256 amountToReturnToUser;

        if (!order.orderDetail.isReduceOnly) {
            // User submitted order.margin when sending the order. Refund the portion of order.margin
            // that executes against the position
            uint256 executedOrderMargin = (order.margin * executedOrderSize) / order.size;
            amountToReturnToUser += executedOrderMargin;
            remainingOrderMargin = order.margin - executedOrderMargin;
        }
        
        if(position.size > executedOrderSize){
            IStore.Asset memory assetInfo = store.getAsset(order.asset);
            require(position.size - executedOrderSize >= assetInfo.minSize,"!min-remaining-size");
        }

        // Calculate fee based on executed order size

        uint256 fee = ((order.fee + (_isTrailingStop ? (executedOrderSize * trailingStopFee) / BPS_DIVIDER : 0) ) * executedOrderSize) / order.size;

        _creditFee(_orderId, order.user, order.asset, order.market, fee, order.orderDetail.executionFee, false, _keeper);

        // If an order is reduce-only, fee is taken from the position's margin.
        uint256 feeToPay = order.orderDetail.isReduceOnly ? fee : 0;

        // FundingTracker update must be before decrementOI
        fundingTracker.updateFundingTracker(order.asset, order.market);

        // Get PNL of position
        (int256 pnl, int256 fundingFee) = getPnL(
            order.asset,
            order.market,
            position.isLong,
            price,
            position.price,
            executedOrderSize,
            position.fundingTracker
        );

        uint256 executedPositionMargin = (position.margin * executedOrderSize) / position.size;

        // If PNL is less than position margin, close position, else update position
        if (pnl <= -1 * int256(uint256(position.margin))) {
            pnl = -1 * int256(uint256(position.margin));
            executedPositionMargin = position.margin;
            executedOrderSize = position.size;
            position.size = 0;
        } else {
            position.margin -= executedPositionMargin.toUint96();
            position.size -= executedOrderSize.toUint96();
            position.fundingTracker = fundingTracker.getFundingTracker(order.asset, order.market);
        }

        _decrementOI(order.asset, order.market, executedOrderSize.toUint96(), position.isLong);

        // Check for maximum pool drawdown
        tradingValidator.checkPoolDrawdown(order.asset, pnl);

        // Credit trader loss or debit trader profit based on pnl
        if (pnl < 0) {
            uint256 absPnl = uint256(-1 * pnl);
            store.creditTraderLoss(order.user, order.asset, order.market, absPnl);

            uint256 totalPnl = absPnl + feeToPay;

            // If an order is reduce-only, fee is taken from the position's margin as the order's margin is zero.
            if (totalPnl < executedPositionMargin) {
                amountToReturnToUser += executedPositionMargin - totalPnl;
            }
        } else {
            store.debitTraderProfit(order.user, order.asset, order.market, uint256(pnl));

            // If an order is reduce-only, fee is taken from the position's margin as the order's margin is zero.
            amountToReturnToUser += executedPositionMargin - feeToPay;
        }

        if (position.size == 0) {
            // Remove position if size == 0
            _remove(order.user, order.asset, order.market);
        } else {
            _addOrUpdate(position);
        }

        // Remove order and transfer funds out
        orderBook.remove(_orderId);
        store.transferOut(order.asset, order.user, amountToReturnToUser);

        emit PositionDecreased(
            _orderId,
            order.user,
            order.asset,
            order.market,
            order.isLong,
            executedOrderSize,
            executedPositionMargin,
            price,
            position.margin,
            position.size,
            position.price,
            position.fundingTracker,
            feeToPay,
            pnl,
            _getUsdAmount(order.asset, pnl),
            fundingFee,
            _isTrailingStop
        );

        // Open position in opposite direction if size remains
        if (!order.orderDetail.isReduceOnly && remainingOrderSize > 0) {

            OrderBook.OrderDetail memory orderDetail = OrderBook.OrderDetail({
                    orderType: 0,
                    isReduceOnly: false,
                    price: 0,
                    expiry: 0,
                    cancelOrderId: 0,
                    executionFee: 0,
                    trailingStopPercentage : 0
                });


            OrderBook.Order memory nextOrder = OrderBook.Order({

                user: order.user,
                margin: remainingOrderMargin.toUint96(),
                asset: order.asset,
                market: order.market,
                isLong: order.isLong,
                size: remainingOrderSize.toUint96(),
                fee: ((order.fee * remainingOrderSize) / order.size).toUint96(),
                timestamp: block.timestamp.toUint32(),
                orderId : 0,
                orderDetail:orderDetail
            });

            uint32 nextOrderId = orderBook.add(nextOrder);

            _increasePosition(nextOrderId, price, _keeper);
        }

        _emitDecreasePositionReferral(order.user, order.asset, executedOrderSize, fee);
    }

    /// @notice Add margin to a position to decrease its leverage and push away its liquidation price
    function addMargin(address _asset, bytes10 _market, uint96 _margin) external payable ifNotPaused {
        address user = msg.sender;

        Position memory position = getPosition(user, _asset, _market);
        require(position.size > 0, '!position');

        // Transfer additional margin in
        if (_asset == address(0)) {
            _margin = msg.value.toUint96();
            store.transferIn{value: _margin}(_asset, user, _margin);
        } else {
            store.transferIn(_asset, user, _margin);
        }

        require(_margin > 0, '!margin');

        // update position margin
        position.margin += _margin;

        // Check if leverage is above minimum leverage
        uint256 leverage = (UNIT * position.size) / position.margin;
        require(leverage >= UNIT, '!min-leverage');

        // update position
        _addOrUpdate(position);

        emit MarginIncreased(user, _asset, _market, _margin, position.margin);
    }

    /// @notice Remove margin from a position to increase its leverage
    /// @dev Margin removal is only available on markets supported by referencePrice
    function removeMargin(address _asset, bytes10 _market, uint256 _margin) external ifNotPaused {
        address user = msg.sender;

        IStore.Market memory marketInfo = store.getMarket(_market);

        Position memory position = getPosition(user, _asset, _market);
        require(position.size > 0, '!position');
        require(position.margin > _margin, '!margin');

        uint256 remainingMargin = position.margin - _margin;

        // Leverage
        uint256 leverageAfterRemoval = (UNIT * position.size) / remainingMargin;
        require(leverageAfterRemoval <= marketInfo.maxLeverage * UNIT, '!max-leverage');

        // This is not available for markets without referencePrice
        uint256 price = referencePriceFeed.getPrice(marketInfo.priceFeedId);
        require(price > 0, '!price');

        (int256 upl, ) = getPnL(
            _asset,
            _market,
            position.isLong,
            price,
            position.price,
            position.size,
            position.fundingTracker
        );

        if (upl < 0) {
            uint256 absUpl = uint256(-1 * upl);
            require(
                absUpl < (remainingMargin * (BPS_DIVIDER - removeMarginBuffer)) / BPS_DIVIDER,
                '!upl'
            );
        }

        // Update position and transfer margin out
        position.margin = remainingMargin.toUint96();
        _addOrUpdate(position);

        store.transferOut(_asset, user, _margin);

        emit MarginDecreased(user, _asset, _market, _margin, position.margin);
    }

    /// @notice Credit fee to Keeper, Pool, and Treasury
    /// @dev Only callable by Executor contract
    function creditFee(
        uint256 _orderId,
        address _user,
        address _asset,
        bytes10 _market,
        uint256 _fee,
        uint256 _executionFee,
        bool _isLiquidation,
        address _keeper
    ) external onlyExecutor {
        _creditFee(_orderId, _user, _asset, _market, _fee, _executionFee, _isLiquidation, _keeper);
    }    

    /// @notice Credit fee to Keeper, Pool, and Treasury
    /// @dev Internal function invoked by {creditFee,_increasePosition,_decreasePosition}
    /// @param _orderId order id
    /// @param _user user address
    /// @param _asset Base asset of position
    /// @param _market Market position was submitted on
    /// @param _fee fee paid
    /// @param _executionFee execution fee with native token
    /// @param _isLiquidation whether position is liquidated
    /// @param _keeper keeper address
    function _creditFee(
        uint256 _orderId,
        address _user,
        address _asset,
        bytes10 _market,
        uint256 _fee,
        uint256 _executionFee,
        bool _isLiquidation,
        address _keeper
    ) internal {
        if (_fee == 0) return;

        // multiply _fee by UNIT (10^18) to increase position
        _fee = _fee * UNIT;

        uint256 keeperFee;
        uint256 netFee = _fee;

        if (keeperFeeShare > 0) {
            keeperFee = (_fee * keeperFeeShare) / BPS_DIVIDER;
            netFee = _fee - keeperFee;
        }

        // Calculate fees
        uint256 feeToPool = (netFee * store.feeShare()) / BPS_DIVIDER;
        uint256 feeToTreasury = netFee - feeToPool;

        // Increment balances, transfer fees out
        // Divide _fee by UNIT to get original _fee value back
        store.incrementBalance(_asset, feeToPool / UNIT);

        store.addFees(_asset, feeToTreasury / UNIT);
        if(keeperFee > 0){
            store.transferOut(_asset, _keeper, keeperFee / UNIT);
        }
        if(_executionFee > 0){
            store.transferOut(address(0), _keeper, _executionFee);
        }

        emit FeePaid(
            _orderId,
            _user,
            _asset,
            _market,
            _fee / UNIT, // paid by user
            feeToPool / UNIT,
            feeToTreasury / UNIT,
            keeperFee / UNIT,
            _executionFee,
            _isLiquidation
        );
    }

    /// @notice Get pnl of a position
    /// @param _asset Base asset of position
    /// @param _market Market position was submitted on
    /// @param _isLong Whether position is long or short
    /// @param _price Current price of market
    /// @param _positionPrice Average execution price of position
    /// @param _size Positions size (margin * leverage) in wei
    /// @param _fundingTracker Market funding rate tracker
    /// @return pnl Profit and loss of position
    /// @return fundingFee Funding fee of position
    function getPnL(
        address _asset,
        bytes10 _market,
        bool _isLong,
        uint256 _price,
        uint256 _positionPrice,
        uint256 _size,
        int256 _fundingTracker
    ) public view returns (int256 pnl, int256 fundingFee) {
        if (_price == 0 || _positionPrice == 0 || _size == 0) return (0, 0);

        if (_isLong) {
            pnl = (int256(_size) * (int256(_price) - int256(_positionPrice))) / int256(_positionPrice);
        } else {
            pnl = (int256(_size) * (int256(_positionPrice) - int256(_price))) / int256(_positionPrice);
        }

        int256 currentFundingTracker = fundingTracker.getNextFundingTracker(_asset, _market);

        fundingFee = (int256(_size) * (currentFundingTracker - _fundingTracker)) / (int256(BPS_DIVIDER) * int256(UNIT)); // funding tracker is in UNIT * bps

        if (_isLong) {
            pnl -= fundingFee; // positive = longs pay, negative = longs receive
        } else {
            pnl += fundingFee; // positive = shorts receive, negative = shorts pay
        }

        return (pnl, fundingFee);
    }

    /// @dev Returns USD value of `_amount` of `_asset`
    /// @dev Used for PositionDecreased event
    function _getUsdAmount(address _asset, int256 _amount) internal view returns (int256) {
        IStore.Asset memory assetInfo = store.getAsset(_asset);
        try referencePriceFeed.getPrice(assetInfo.priceFeedId) returns(uint256 referencePrice) {
            // _amount is in the asset's decimals, convert to 18. Price is 18 decimals
            return (_amount * int256(referencePrice)) / int256(10 ** assetInfo.decimals);
        } catch { // if price is not valid, dont revert tx.
            return 0;
        }
    }

    /// @dev emit increase position referral event
    function _emitIncreasePositionReferral(address _account, address _asset, uint256 _sizeDelta, uint256 _fee) internal {
        if (address(referralStorage) == address(0)) { return; }


        (bytes32 referralCode, address referrer) = referralStorage.getTraderReferralInfo(_account);
        if (referralCode == bytes32(0)) { return; }

        emit IncreasePositionReferral(
            _account,
            _asset,
            _sizeDelta,
            _fee,
            referralCode,
            referrer
        );
    }

    /// @dev emit decrease position referral event
    function _emitDecreasePositionReferral(address _account, address _asset, uint256 _sizeDelta, uint256 _fee) internal {
        if (address(referralStorage) == address(0)) { return; }


        (bytes32 referralCode, address referrer) = referralStorage.getTraderReferralInfo(_account);
        if (referralCode == bytes32(0)) { return; }

        emit DecreasePositionReferral(
            _account,
            _asset,
            _sizeDelta,
            _fee,
            referralCode,
            referrer
        );
    }

    /// @notice Adds new position or updates exisiting one
    /// @dev Only callable by other protocol contracts
    /// @param _position Position to add/update
    function _addOrUpdate(Position memory _position) internal  {
        bytes32 key = _getPositionKey(_position.user, _position.asset, _position.market);
        positions[key] = _position;
        positionKeysForUser[_position.user].add(key);
        positionKeys.add(key);
    }

    /// @notice Removes position
    /// @dev Only callable by Executor contract
    /// @param _user User address
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function remove(address _user, address _asset, bytes10 _market) external onlyExecutor {
        _remove(_user, _asset, _market);
    }

    /// @notice Removes position
    /// @dev Internal function invoked by {remove, _decreasePosition}
    function _remove(address _user, address _asset, bytes10 _market) internal {
        bytes32 key = _getPositionKey(_user, _asset, _market);
        positionKeysForUser[_user].remove(key);
        positionKeys.remove(key);
        delete positions[key];
        emit RemovePosition(_user,_asset,_market);
    }

    /// @notice Increments open interest
    /// @dev Invoked by increasePosition
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD"
    /// @param _amount position size amount
    /// @param _isLong Whether position is long or short 
    function _incrementOI(address _asset, bytes10 _market, uint96 _amount, bool _isLong) internal {
        if (_isLong) {
            OI[_asset][_market].long += _amount;
            assetOI[_asset].long += _amount;
        } else {
            OI[_asset][_market].short += _amount;
            assetOI[_asset].short += _amount;
        }
        emit IncrementOI(_asset, _market, _amount, _isLong);
    }

    /// @notice Decrements open interest
    /// @dev Only callable by Executor contract
    /// @dev Invoked whenever a position is closed or decreased
    function decrementOI(address _asset, bytes10 _market, uint96 _amount, bool _isLong) external onlyExecutor {
        _decrementOI(_asset, _market, _amount, _isLong);
    }

    /// @notice Decrements open interest
    /// @dev internal function
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD"
    /// @param _amount position size amount
    /// @param _isLong Whether position is long or short 
    function _decrementOI(address _asset, bytes10 _market, uint96 _amount, bool _isLong) internal {
        
        if (_isLong) {
            uint128 long = OI[_asset][_market].long;
            OI[_asset][_market].long = long <= _amount ? 0 : long - _amount;
            uint128 assetLong = assetOI[_asset].long;
            assetOI[_asset].long = assetLong <= _amount ? 0 : assetLong - _amount;
        } else {
            uint128 short = OI[_asset][_market].short;
            OI[_asset][_market].short = short <= _amount ? 0 : short - _amount;
            uint128 assetShort = assetOI[_asset].short;
            assetOI[_asset].short = assetShort <= _amount ? 0 : assetShort - _amount;
        }
        emit DecrementOI(_asset, _market, _amount, _isLong);
    }

    /// @notice Returns open interest of `_asset` and `_market`
    function getOI(address _asset,bytes10 _market) external view returns (uint256) {
        OpenInterest memory oi = OI[_asset][_market];
        return oi.long + oi.short;
    }

    /// @notice Returns open interest of `_asset` 
    function getAssetOI(address _asset) external view returns (uint256) {
        OpenInterest memory oi = assetOI[_asset];
        return oi.long + oi.short;
    }

    
    /// @notice Returns open interest of long positions of `_asset`
    function getAssetOILong(address _asset) external view returns (uint256) {
        return assetOI[_asset].long;
    }

    /// @notice Returns open interest of short positions of `_asset`
    function getAssetOIShort(address _asset) external view returns (uint256) {
        return assetOI[_asset].short;
    }

    /// @notice Returns open interest of long positions of `_asset` and `_market`
    function getOILong(address _asset, bytes10 _market) external view returns (uint256) {
        return OI[_asset][_market].long;
    }

    /// @notice Returns open interest of short positions of `_asset` and `_market`
    function getOIShort(address _asset, bytes10 _market) external view returns (uint256) {
        return OI[_asset][_market].short;
    }


    /// @notice Returns position of `_user`
    /// @param _asset Base asset of position
    /// @param _market Market this position was submitted on
    function getPosition(address _user, address _asset, bytes10 _market) public view returns (Position memory) {
        bytes32 key = _getPositionKey(_user, _asset, _market);
        return positions[key];
    }

    /// @notice Returns positions of `_users`
    /// @param _assets Base assets of positions
    /// @param _markets Markets of positions
    function getPositions(
        address[] calldata _users,
        address[] calldata _assets,
        bytes10[] calldata _markets
    ) external view returns (Position[] memory) {
        uint256 length = _users.length;
        Position[] memory _positions = new Position[](length);

        for (uint256 i; i < length; i++) {
            _positions[i] = getPosition(_users[i], _assets[i], _markets[i]);
        }

        return _positions;
    }

    /// @notice Returns positions
    /// @param _keys Position keys
    function getPositions(bytes32[] calldata _keys) external view returns (Position[] memory) {
        uint256 length = _keys.length;
        Position[] memory positionList = new Position[](length);

        for (uint256 i; i < length; i++) {
            positionList[i] = positions[_keys[i]];
        }

        return positionList;
    }

    /// @notice Returns number of positions
    function getPositionCount() external view returns (uint256) {
        return positionKeys.length();
    }

    /// @notice Returns `_length` amount of positions starting from `_offset`
    function getPositions(uint256 _length, uint256 _offset) external view returns (Position[] memory) {
        uint256 keyslength = positionKeys.length();
        if (_length + _offset > keyslength) _length = keyslength - _offset;
        Position[] memory _positions = new Position[](_length);

        for (uint256 i; i < _length ; i++) {
            _positions[i] = positions[positionKeys.at(i+_offset)];
        }

        return _positions;
    }

    /// @notice Returns all positions of `_user`
    function getUserPositions(address _user) external view returns (Position[] memory) {
        uint256 length = positionKeysForUser[_user].length();
        Position[] memory _positions = new Position[](length);

        for (uint256 i; i < length; i++) {
            _positions[i] = positions[positionKeysForUser[_user].at(i)];
        }

        return _positions;
    }

    /// @dev Returns position key by hashing (user, asset, market)
    function _getPositionKey(address _user, address _asset, bytes10 _market) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_user, _asset, _market));
    }

}
