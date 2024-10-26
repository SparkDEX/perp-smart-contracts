// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import '@openzeppelin/contracts/utils/math/SafeCast.sol';


import './utils/AddressStorage.sol';
import './Store.sol';
import './utils/interfaces/IStore.sol';
import './utils/TradingValidator.sol';
import './PositionManager.sol';
import './interfaces/IReferralStorage.sol';
import './utils/FTSOv2.sol';
import './Executor.sol';

import './utils/Governable.sol';

/**
 * @title  OrderBook
 * @notice Implementation of order related logic, i.e. submitting orders / cancelling them
 */
contract OrderBook is Governable {
    // Libraries
    using EnumerableSet for EnumerableSet.UintSet;
    using Address for address payable;
    using SafeCast for uint256;


    // Constants
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_TRAILING_STOP_PERCENTAGE = 2000;
    uint256 public constant MAX_ORDER_EXECUTION_FEE = 2 * 10 ** 18;  // max gas price of execution tx , flare specific

    // Order struct

    struct OrderDetail{ 
        uint8 orderType; // 0 = market, 1 = limit, 2 = stop , 3 = trailing stop   
        bool isReduceOnly; // Whether the order is reduce-only
        uint96 price; // The order's price if its a trigger or protected order 
        uint32 expiry; // block.timestamp at which the order expires           
        uint32 cancelOrderId; // orderId to cancel when this order executes 
        uint64 executionFee; //Fee paid with native token for keeper's execution
        uint16 trailingStopPercentage; //Trailing stop percentage in bps e.g. 200 for %2
    }

    struct Order { 
        address user; // user that submitted the order 
        uint96 margin; // Collateral tied to this order. In wei 
        address asset; // Asset address, e.g. address(0) for ETH 
        bytes10 market; // Market this order was submitted on     
        bool isLong; // Whether the order is a buy or sell order
        uint96 size; // Order size (margin * leverage). In wei
        uint96 fee; // Fee amount paid. In wei
        uint32 timestamp; // block.timestamp at which the order was submitted
        uint32 orderId;  // incremental order id 
        OrderDetail orderDetail; 
    }

    uint32 public oid; // incremental order id
    mapping(uint32 => Order) private orders; // order id => Order
    mapping(address => EnumerableSet.UintSet) private userOrderIds; // user => [order ids..]
    EnumerableSet.UintSet private marketOrderIds; // [order ids..]
    EnumerableSet.UintSet private triggerOrderIds; // [order ids..]

    uint256 public maxMarketOrderTTL = 5 minutes;  // duration until market orders expire
    uint256 public maxTriggerOrderTTL = 180 days;  // duration until trigger orders expire

    uint64 public orderExecutionFee;  //  fee with native token required for the execution of the order by keepers

    bool public areNewOrdersPaused;
    bool public isProcessingPaused;
    bool public isSelfExecutionActive;

    bytes32 public ethSignedMessageHash;  // Message Hash equivalent of UI  sign message of enable orders, remix.ethereum.org can be used for message hash

    mapping(address => bool) public whitelistedFundingAccount;  // accounts authorized to open positions on behalf of another user

    mapping(address => bool) public approvedAccounts; // accounts approved to submit order

    // Events

    // Order of function / event params: id, user, asset, market
    event OrderCreated(
        uint32 indexed orderId,
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint96 margin,
        uint96 size,
        uint96 price,
        uint96 fee,
        bool isLong,
        uint8 orderType,
        bool isReduceOnly,
        uint32 expiry,
        uint32 cancelOrderId,
        address fundingAccount,
        uint64 executionFee,
        uint16 trailingStopPercentage
    );

    event OrderCancelled(uint32 indexed orderId, address indexed user, address executionFeeReceiver, string reason);
    event AccountApproved(address indexed user, bool signed, bool byGov);
    event EthSignedMessageHashUpdated(bytes32 ethSignedMessageHash);  
    event WhitelistedFundingAccountUpdated(address indexed account, bool isActive);
    event MaxMarketOrderTTLUpdated(uint256 maxMarketOrderTTL);
    event MaxTriggerOrderTTLUpdated(uint256 maxTriggerOrderTTL);
    event OrderExecutionFeeUpdated(uint64 orderExecutionFee);
    event Link(address store, address tradingValidator, address referralStorage, address executor, address positionManager, address ftsoV2);
    event NewOrdersPaused(bool orderPaused);
    event ProcessingPaused(bool processingPaused);
    event SelfExecutionActive(bool isSelfExecutionActive);

    event AddOrder(uint32 indexed orderId, uint8 orderType);
    event RemoveOrder(uint32 indexed orderId, uint8 orderType);

    // Contracts
    AddressStorage public immutable addressStorage;
    Store public store;
    PositionManager public positionManager;
    TradingValidator public tradingValidator;
    IReferralStorage public referralStorage;
    FTSOv2 public ftsoV2;

    Executor public executor;

    /// @dev Reverts if order processing is paused
    modifier ifNotPaused() {
        require(!areNewOrdersPaused, '!paused');
        _;
    }

    /// @dev Only callable by Executor contract
    modifier onlyExecutor() {
        require(msg.sender == address(executor), "!unauthorized");
        _;
    }

    /// @dev Only callable by PositionManager contract
    modifier onlyPositionManager() {
        require(msg.sender == address(positionManager), "!unauthorized");
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
    }

    /// @notice Set EthSignedMessageHash
    /// @dev Only callable by governance
    /// @param _messageHash Message Hash,remix.ethereum.org can be used 
    function setEthSignedMessageHash(bytes32 _messageHash) external onlyGov {
        ethSignedMessageHash = _messageHash;
        emit EthSignedMessageHashUpdated(_messageHash);
    }

    /// @notice Set whitelisted Funding Account
    /// @dev Only callable by governance
    /// @param _account  accounts authorized to open positions on behalf of another user
    /// @param _isActive whether account is active
    function setWhitelistedFundingAccount(address _account, bool _isActive) external onlyGov {
        whitelistedFundingAccount[_account] = _isActive;
        emit WhitelistedFundingAccountUpdated(_account,_isActive);
    }

    /// @notice Disable submitting new orders
    /// @dev Only callable by governance
    function setAreNewOrdersPaused(bool _areNewOrdersPaused) external onlyGov {
        areNewOrdersPaused = _areNewOrdersPaused;
        emit NewOrdersPaused(areNewOrdersPaused);
    }

    /// @notice Disable processing new orders
    /// @dev Only callable by governance
    function setIsProcessingPaused(bool _isProcessingPaused) external onlyGov {
        isProcessingPaused = _isProcessingPaused;
        emit ProcessingPaused(isProcessingPaused);
    }

    /// @notice Enable/Disable self execution new orders
    /// @dev Only callable by governance
    function setIsSelfExecutionActive(bool _isSelfExecutionActive) external onlyGov {
        isSelfExecutionActive = _isSelfExecutionActive;
        emit SelfExecutionActive(isSelfExecutionActive);
    }

    /// @notice Set duration until market orders expire
    /// @dev Only callable by governance
    /// @param _maxMarketOrderTTL Duration in seconds
    function setMaxMarketOrderTTL(uint256 _maxMarketOrderTTL) external onlyGov {
        require(_maxMarketOrderTTL > 0, '!gt_zero'); // greater than zero
        require(_maxMarketOrderTTL < maxTriggerOrderTTL, '!lt_triggerttl'); // must be less than trigger ttl value
        maxMarketOrderTTL = _maxMarketOrderTTL;
        emit MaxMarketOrderTTLUpdated(_maxMarketOrderTTL);
    }

    /// @notice Set duration until trigger orders expire
    /// @dev Only callable by governance
    /// @param _maxTriggerOrderTTL Duration in seconds
    function setMaxTriggerOrderTTL(uint256 _maxTriggerOrderTTL) external onlyGov {
        require(_maxTriggerOrderTTL > 0, '!gtzero'); // greater than zero
        require(_maxTriggerOrderTTL > maxMarketOrderTTL, '!gt_marketttl'); // must be greater than market ttl value
        maxTriggerOrderTTL = _maxTriggerOrderTTL;
        emit MaxTriggerOrderTTLUpdated(_maxTriggerOrderTTL);
    }

    /// @notice Set keeper gas fee for order execution 
    /// @dev Only callable by governance
    /// @param _orderExecutionFee Fee with native token e.g. ETH
    function setOrderExecutionFee(uint64 _orderExecutionFee) external onlyGov {
        require(_orderExecutionFee <= MAX_ORDER_EXECUTION_FEE, '!max-execution-fee'); 
        orderExecutionFee = _orderExecutionFee;
        emit OrderExecutionFeeUpdated(_orderExecutionFee);
    }

    /// @notice Enable order with onchain function
    function enableOrder() external {
        approvedAccounts[msg.sender] = true;
        emit AccountApproved(msg.sender,false,false);
    }   

    /// @notice Enable order function for accounts like contract
    /// @dev Only callable by governance
    /// @param _account EOA or contract account
    function enableOrderByGov(address _account) external onlyGov{
        approvedAccounts[_account] = true;
        emit AccountApproved(msg.sender, false, true);
    }   

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        store = Store(payable(addressStorage.getAddress('Store')));
        tradingValidator = TradingValidator(addressStorage.getAddress('TradingValidator'));
        referralStorage = IReferralStorage(addressStorage.getAddress('ReferralStorage'));
        executor = Executor(addressStorage.getAddress('Executor'));
        positionManager = PositionManager(addressStorage.getAddress('PositionManager'));
        ftsoV2 = FTSOv2(addressStorage.getAddress('FTSOv2'));
        emit Link(
            address(store),
            address(tradingValidator),
            address(referralStorage),
            address(executor),
            address(positionManager),
            address(ftsoV2)
        );
    }

    /// @notice Submits a new order with signature, 
    /// @dev will be called from the UI only the first time because of gas saving
    /// @param _params Order to submit
    /// @param _tpPrice 18 decimal take profit price
    /// @param _slPrice 18 decimal stop loss price
    /// @param _trailingStopPercentage trailing stop percentage 
    /// @param _referralCode code for referral system    
    /// @param _signature user signature for enabling order
    function submitOrderWithSignature(
        Order memory _params,
        uint96 _tpPrice,
        uint96 _slPrice,
        uint16 _trailingStopPercentage,
        bytes32 _referralCode,
        bytes memory _signature
    ) external payable ifNotPaused {
        require(approvedAccounts[msg.sender] || SignatureChecker.isValidSignatureNow(msg.sender,ethSignedMessageHash, _signature),"!not signed");
        if(!approvedAccounts[msg.sender]){
            approvedAccounts[msg.sender] = true;
            emit AccountApproved(msg.sender, true, false);
        }

        _submitOrder(_params,_tpPrice,_slPrice,_trailingStopPercentage,_referralCode);
    }      


    /// @notice Submits a new order
    /// @param _params Order to submit
    /// @param _tpPrice 18 decimal take profit price
    /// @param _slPrice 18 decimal stop loss price
    /// @param _trailingStopPercentage trailing stop percentage 
    /// @param _referralCode code for referral system    
    function submitOrder(
        Order memory _params,
        uint96 _tpPrice,
        uint96 _slPrice,
        uint16 _trailingStopPercentage,
        bytes32 _referralCode
    ) external payable ifNotPaused {
        require(approvedAccounts[msg.sender]  ,"!not approved");
        _submitOrder(_params,_tpPrice,_slPrice,_trailingStopPercentage,_referralCode);
    }      

    /// @notice Submits a new order
    /// @dev Internal function invoked by {submitOrderWithSignature,submitOrder} 
    function _submitOrder(
        Order memory _params,
        uint96 _tpPrice,
        uint96 _slPrice,
        uint16 _trailingStopPercentage,
        bytes32 _referralCode
    ) internal {
        // order cant be reduce-only if take profit or stop loss order is submitted alongside main order
        if (_tpPrice > 0 || _slPrice > 0 || _trailingStopPercentage > 0) {
            _params.orderDetail.isReduceOnly = false;
        }
        
        if (_params.orderDetail.isReduceOnly || _params.orderDetail.orderType == 3){
            if(_params.orderDetail.orderType == 3){
                require(_params.orderDetail.isReduceOnly , '!trailing-stop-must-reduce');
                _params.orderDetail.price = 0; // must be zero to distinguish it from a limit order ts
            }
            PositionManager.Position memory position = positionManager.getPosition(msg.sender, _params.asset, _params.market);
            require(position.size > 0 , '!no-position');
            require(position.isLong != _params.isLong , '!reduce-wrong-direction');
        }

        _params.user = _orderUser(_params);
        if(_params.user != msg.sender){
            _params.orderDetail.cancelOrderId = 0;
        }
        _params.orderDetail.executionFee = orderExecutionFee;

        uint256 totalExecutionFee = _params.orderDetail.executionFee;
        uint8 mainOrderType = _params.orderDetail.orderType;
        // Submit order
        uint256 valueConsumed;
        uint32 orderId;
        (orderId, valueConsumed) = _submitOrder(_params);

        if (_referralCode != bytes32(0) && address(referralStorage) != address(0)) {
            referralStorage.setTraderReferralCode(_params.user, _referralCode);
        }

        // tp/sl price checks
        if (_tpPrice > 0 || _slPrice > 0 || _trailingStopPercentage > 0) {
            if (_params.orderDetail.price > 0 ) {
                if (_tpPrice > 0) {
                    require(
                        (_params.isLong && _tpPrice > _params.orderDetail.price) || (!_params.isLong && _tpPrice < _params.orderDetail.price),
                        '!tp-invalid'
                    );
                }
                if (_slPrice > 0 ) {
                    require(
                        (_params.isLong && _slPrice < _params.orderDetail.price) || (!_params.isLong && _slPrice > _params.orderDetail.price),
                        '!sl-invalid'
                    );
                }
            }

            if (_tpPrice > 0 && _slPrice > 0) {
                require((_params.isLong && _tpPrice > _slPrice) || (!_params.isLong && _tpPrice < _slPrice), '!tpsl-invalid');
            }

            // tp and sl order ids
            uint32 tpOrderId;
            uint32 slOrderId;

            // long -> short, short -> long for take profit / stop loss order
            _params.isLong = !_params.isLong;

            // reset order expiry for TP/SL orders
            if (_params.orderDetail.expiry > 0) _params.orderDetail.expiry = 0;

            // submit stop loss order
            if (_slPrice > 0 ) {
                _params.orderDetail.price = _slPrice;
                _params.orderDetail.orderType = 2;
                _params.orderDetail.isReduceOnly = true;
                totalExecutionFee += _params.orderDetail.executionFee;
                // Order is reduce-only so valueConsumed is always zero
                (slOrderId, ) = _submitOrder(_params);
            } else if (_trailingStopPercentage > 0){
                _params.orderDetail.orderType = 3;
                _params.orderDetail.isReduceOnly = true;
                _params.orderDetail.trailingStopPercentage = _trailingStopPercentage;
                totalExecutionFee += _params.orderDetail.executionFee;
                // Order is reduce-only so valueConsumed is always zero
                (slOrderId, ) = _submitOrder(_params);
            }

            // submit take profit order
            if (_tpPrice > 0) {
                _params.orderDetail.price = _tpPrice;
                _params.orderDetail.orderType = 1;
                _params.orderDetail.isReduceOnly = true;
                _params.orderDetail.trailingStopPercentage = 0;
                totalExecutionFee += _params.orderDetail.executionFee;
                // Order is reduce-only so valueConsumed is always zero
                (tpOrderId, ) = _submitOrder(_params);
            }


            // Update orders to cancel each other
            if (tpOrderId > 0 && slOrderId > 0) {
                _updateCancelOrderId(tpOrderId, slOrderId);
                _updateCancelOrderId(slOrderId, tpOrderId);
            }
        }
        uint256 priceFeedFee;
        if(isSelfExecutionActive){
            IStore.Market memory market = store.getMarket(_params.market);
            if(market.minOrderAge == 0 && mainOrderType == 0){
                priceFeedFee = ftsoV2.getFee(market.priceFeedId);
                uint32[] memory orderIds = new uint32[](1);
                bytes21[] memory priceFeedIds = new bytes21[](1);
                orderIds[0] = orderId;
                priceFeedIds[0] = market.priceFeedId;
                uint256 remainingMsgValue = executor.executeOrders{value:priceFeedFee}(orderIds,priceFeedIds,_params.user);
                priceFeedFee -= remainingMsgValue;
            }
            
        }

        uint256 requiredValue = (_params.asset == address(0) ? valueConsumed : 0) + totalExecutionFee + priceFeedFee;
        require(msg.value >= requiredValue,"!msg-value");
        uint256 diff = msg.value - requiredValue;
        if (diff > 0) {
            payable(_params.user).sendValue(diff);
        }
    }

    /// @notice Submits a new order
    /// @dev Internal function invoked by {_submitOrder} 
    function _submitOrder(Order memory _params) internal returns (uint32, uint96) {
        // Validations
        require(_params.orderDetail.orderType < 4, '!order-type');

        // execution price of trigger order cant be zero
        if (_params.orderDetail.orderType == 1 || _params.orderDetail.orderType == 2) {
            require(_params.orderDetail.price > 0, '!price');
        } else if (_params.orderDetail.orderType == 3) {
            require(_params.orderDetail.trailingStopPercentage > 0 &&  _params.orderDetail.trailingStopPercentage <= MAX_TRAILING_STOP_PERCENTAGE, '!trailing-stop-invalid');
        }

        // check if base asset is supported and order size is above min size
        IStore.Asset memory asset = store.getAsset(_params.asset);
        require(asset.minSize > 0, '!asset-exists');
        require(_params.orderDetail.isReduceOnly || _params.size >= asset.minSize, '!min-size');

        // check if market exists
        IStore.Market memory market = store.getMarket(_params.market);
        require(market.maxLeverage > 0, '!market-exists');

        // Order expiry validations
        if (_params.orderDetail.expiry > 0) {
            // expiry value cant be in the past
            require(_params.orderDetail.expiry >= block.timestamp, '!expiry-value');

            // _params.expiry cant be after default expiry of market and trigger orders
            uint256 ttl = _params.orderDetail.expiry - block.timestamp;
            if (_params.orderDetail.orderType == 0) require(ttl <= maxMarketOrderTTL, '!max-expiry');
            else require(ttl <= maxTriggerOrderTTL, '!max-expiry');
        }

        // cant cancel an order of another user
        if (_params.orderDetail.cancelOrderId > 0) {
            require(userOrderIds[_params.user].contains(_params.orderDetail.cancelOrderId), '!user-oco');
        }

        // Set timestamp
        _params.timestamp = block.timestamp.toUint32();        
        _params.fee = (_params.size * market.fee / BPS_DIVIDER).toUint96();
        uint96 valueConsumed;
        bool isSentNative;


        if (_params.orderDetail.isReduceOnly) {
            _params.margin = 0;

            // Existing position is checked on execution so TP/SL can be submitted as reduce-only alongside a non-executed order
            // In this case, valueConsumed is zero as margin is zero and fee is taken from the order's margin when position is executed
        } else {
            require(!market.isReduceOnly, '!market-reduce-only');
            require(_params.margin > 0, '!margin');

            uint256 leverage = (UNIT * _params.size) / _params.margin;
            require(leverage >= UNIT, '!min-leverage');
            require(leverage <= market.maxLeverage * UNIT, '!max-leverage');

            // Check against max OI if it's not reduce-only. this is not completely fail safe as user can place many
            // consecutive market orders of smaller size and get past the max OI limit here, because OI is not updated until
            // keeper picks up the order. That is why maxOI is checked on processing as well, which is fail safe.
            // This check is more of preemptive for user to not submit an order
            tradingValidator.checkMaxOI(_params.asset, _params.market, _params.size);

            // Transfer fee and margin to store
            valueConsumed = _params.margin + _params.fee;

            if (_params.asset == address(0)) {
                store.transferIn{value: valueConsumed + _params.orderDetail.executionFee }(_params.asset, msg.sender, valueConsumed + _params.orderDetail.executionFee);
                isSentNative = true;
            } else {
                store.transferIn(_params.asset, msg.sender, valueConsumed);
            }
        }

        if(_params.orderDetail.executionFee > 0 && !isSentNative){
            store.transferIn{value: _params.orderDetail.executionFee}(address(0), msg.sender, _params.orderDetail.executionFee);
        }

        // Add order to store and emit event
        _params.orderId = _add(_params);

        emit OrderCreated(
            _params.orderId,
            _params.user,
            _params.asset,
            _params.market,
            _params.margin,
            _params.size,
            _params.orderDetail.price,
            _params.fee,
            _params.isLong,
            _params.orderDetail.orderType,
            _params.orderDetail.isReduceOnly,
            _params.orderDetail.expiry,
            _params.orderDetail.cancelOrderId,
            msg.sender,
            _params.orderDetail.executionFee,
            _params.orderDetail.trailingStopPercentage
        );

        return (_params.orderId, valueConsumed);
    }

    /// @notice Cancels order
    /// @param _orderId Order to cancel
    function cancelOrder(uint32 _orderId) external ifNotPaused {
        Order memory order = orders[_orderId];
        require(order.size > 0, '!order');
        require(order.user == msg.sender, '!user');
        _cancelOrder(_orderId, 'by-user', msg.sender);
    }

    /// @notice Cancel several orders
    /// @param _orderIds Array of orderIds to cancel
    function cancelOrders(uint32[] calldata _orderIds) external ifNotPaused {
        for (uint32 i; i < _orderIds.length; i++) {
            Order memory order = orders[_orderIds[i]];
            if (order.size > 0 && order.user == msg.sender) {
                _cancelOrder(_orderIds[i], 'by-user', msg.sender);
            }
        }
    }

    /// @notice Cancels order
    /// @dev Only callable by Executor contract
    /// @param _orderId Order to cancel
    /// @param _reason Cancellation reason
    /// @param _executionFeeReceiver Address of execution fee receiver
    function cancelOrder(uint32 _orderId, string calldata _reason, address _executionFeeReceiver) external onlyExecutor {
        _cancelOrder(_orderId, _reason, _executionFeeReceiver);
    }

    /// @notice Cancels order
    /// @dev Internal function without access restriction
    /// @param _orderId Order to cancel
    /// @param _reason Cancellation reason
    /// @param _executionFeeReceiver Address of execution fee receiver
    function _cancelOrder(uint32 _orderId, string memory _reason, address _executionFeeReceiver) internal {
        Order memory order = orders[_orderId];
        if (order.size == 0) return;

        _remove(_orderId);
        bool isSentNative;

        if (!order.orderDetail.isReduceOnly) {
            isSentNative = order.asset == address(0) && order.user == _executionFeeReceiver;
            store.transferOut(order.asset, order.user, order.margin + order.fee + (isSentNative ? order.orderDetail.executionFee : 0));
        }

        if(order.orderDetail.executionFee > 0 && !isSentNative){
            store.transferOut(address(0), _executionFeeReceiver, order.orderDetail.executionFee);
        }

        emit OrderCancelled(_orderId, order.user, _executionFeeReceiver, _reason);
    }

    /// @notice Get order user 
    /// @dev if sender is whitelisted funding account and order is suitable, The user is being made incoming in the params 
    /// @param _params Order params
    /// @return user order user
    function _orderUser(Order memory _params) internal view returns (address) {
        if(whitelistedFundingAccount[msg.sender]){
            require(_params.user != address(0) && !_params.orderDetail.isReduceOnly && _params.orderDetail.orderType == 0,"funding-account-order-fail");
            return _params.user;        
        }
        return msg.sender;
    }

    /// @notice Adds order to storage
    /// @dev Only callable by PositionManager contract
    function add(Order memory _order) external onlyPositionManager returns (uint32) {
        return _add(_order);
    }

    /// @notice  Adds order to storage
    /// @dev Internal function
    function _add(Order memory _order) internal returns (uint32) {
        uint32 nextOrderId = ++oid;
        _order.orderId = nextOrderId;
        orders[nextOrderId] = _order;
        userOrderIds[_order.user].add(nextOrderId);
        if (_order.orderDetail.orderType == 0) {
            marketOrderIds.add(nextOrderId);
        } else {
            triggerOrderIds.add(nextOrderId);
        }
        emit AddOrder(nextOrderId, _order.orderDetail.orderType);

        return nextOrderId;
    }

    /// @notice Removes order from store
    /// @dev Only callable by PositionManager contract
    /// @param _orderId Order to remove
    function remove(uint32 _orderId) external onlyPositionManager {
        _remove(_orderId);
    }

    /// @notice  Removes order from store
    /// @dev Internal function
    /// @param _orderId Order to remove
    function _remove(uint32 _orderId) internal {
        Order memory order = orders[_orderId];
        if (order.size == 0) return;
        userOrderIds[order.user].remove(_orderId);
        marketOrderIds.remove(_orderId);
        triggerOrderIds.remove(_orderId);
        emit RemoveOrder(_orderId, order.orderDetail.orderType);
        delete orders[_orderId];

        
    }

    /// @notice Updates `cancelOrderId` of `orderId`, e.g. TP order cancels a SL order and vice versa
    /// @dev Internal function
    /// @param _orderId Order which cancels `cancelOrderId` on execution
    /// @param _cancelOrderId Order to cancel when `orderId` executes
    function _updateCancelOrderId(uint32 _orderId, uint32 _cancelOrderId) internal {
        OrderDetail storage orderDetail = orders[_orderId].orderDetail;
        orderDetail.cancelOrderId = _cancelOrderId;
    }

    /// @notice Returns a single order
    /// @param _orderId Order to get
    function get(uint32 _orderId) external view returns (Order memory) {
        return orders[_orderId];
    }

    /// @notice Returns many orders
    /// @param _orderIds Orders to get, e.g. [1, 2, 5]
    function getMany(uint32[] calldata _orderIds) external view returns (Order[] memory) {
        uint256 length = _orderIds.length;
        Order[] memory _orders = new Order[](length);

        for (uint256 i; i < length; i++) {
            _orders[i] = orders[_orderIds[i]];
        }

        return _orders;
    }

    /// @notice Returns market orders
    /// @param _length Amount of market orders to return
    function getMarketOrders(uint256 _length) external view returns (Order[] memory) {
        uint32 marketOrderlength = marketOrderIds.length().toUint32();
        if (_length > marketOrderlength) _length = marketOrderlength;

        Order[] memory _orders = new Order[](_length);

        for (uint256 i; i < _length; i++) {
            _orders[i] = orders[marketOrderIds.at(i).toUint32()];
        }

        return _orders;
    }

    /// @notice Returns trigger orders
    /// @param _length Amount of trigger orders to return
    /// @param _offset Offset to start
    function getTriggerOrders(uint256 _length, uint256 _offset) external view returns (Order[] memory) {
        uint32 triggerOrderlength = triggerOrderIds.length().toUint32();
        if (_length + _offset > triggerOrderlength) _length = triggerOrderlength - _offset; 

        Order[] memory _orders = new Order[](_length);

        for (uint256 i; i < _length ; i++) {
            _orders[i] = orders[triggerOrderIds.at(i+_offset).toUint32()];
        }

        return _orders;
    }

    /// @notice Returns orders of `user`    
    function getUserOrders(address _user) external view returns (Order[] memory) {
        uint32 length = userOrderIds[_user].length().toUint32();
        Order[] memory _orders = new Order[](length);

        for (uint256 i; i < length; i++) {
            _orders[i] = orders[userOrderIds[_user].at(i).toUint32()];
        }

        return _orders;
    }

    /// @notice Returns amount of market orders
    function getMarketOrderCount() external view returns (uint256) {
        return marketOrderIds.length();
    }

    /// @notice Returns amount of trigger orders
    function getTriggerOrderCount() external view returns (uint256) {
        return triggerOrderIds.length();
    }

    /// @notice Returns order amount of `user`
    function getUserOrderCount(address _user) external view returns (uint256) {
        return userOrderIds[_user].length();
    }

}
