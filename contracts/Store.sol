// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import './utils/AddressStorage.sol';
import './utils/Governable.sol';
import './utils/interfaces/IStore.sol';
import './PositionManager.sol';

/**
 * @title  Store
 * @notice Users can deposit supported assets to back trader profits and receive
 *         a share of trader losses. Each asset pool is siloed, e.g. the ETH
 *         pool is independent from the USDC pool.
 *         Persistent storage of supported assets
 *         Persistent storage of supported markets
 *         Storage of protocol funds
 */
contract Store is Governable, ReentrancyGuard, IStore {
    // Libraries
    using SafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeCast for uint256;

    // Constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_FEE = 1000; // 10%
    uint256 public constant MAX_DEVIATION = 1000; // 10%
    uint256 public constant MAX_LIQTHRESHOLD = 9800; // 98%
    uint256 public constant MAX_MIN_ORDER_AGE = 30; //seconds
    uint256 public constant MIN_MAX_AGE = 3; //seconds
    uint256 public constant MAX_BUFFER_PAYOUT_PERIOD = 7 days;
    uint256 public constant MAX_PRICE_SPREAD = 500; // 5% 


    // Liquidity struct
    enum LiquidityType {
        DEPOSIT,
        WITHDRAW
    }    

    struct LiquidityOrder { 
        address asset; // Asset address, e.g. address(0) for ETH
        uint96 amount; // liquidity order amount
        address user; // user that submitted the order
        uint32 liquidityOrderId;  // incremental order id 
        LiquidityType orderType; // 0- Deposit, 1- Withdraw
        uint32 timestamp; // block.timestamp at which the order was submitted
        uint96 minAmountMinusTax; // realised amount minus tax must be greater than this value
        uint64 executionFee; //Fee paid with native token for keeper's execution
    }

    // State variables
    uint256 public feeShare = 500;
    uint256 public bufferPayoutPeriod = 7 days;
    bool public isPublicDeposit;
    uint256 public maxLiquidityOrderTTL = 5 minutes;
    uint32 public liquidityOid; // incremental liquidity order id
    mapping(uint32 => LiquidityOrder) private liquidityOrders; // order id => Order
    mapping(address => EnumerableSet.UintSet) private userLiquidityOrderIds; // user => [order ids..]
    EnumerableSet.UintSet private liquidityOrderIds; // [order ids..]
    uint64 public orderExecutionFee;  //  fee with native token required for the execution of the order by keepers

    // Asset list
    address[] public assetList;
    mapping(address => Asset) private assets;

    // Market list
    bytes10[] public marketList; 
    mapping(bytes10 => Market) private markets;

    mapping(address => uint256) private utilizationMultipliers; // asset => utilization multiplier , for maxOI control

    mapping(address => uint256) private lpSupply; // asset => lp supply
    mapping(address => uint256) private balances; // asset => balance
    mapping(address => mapping(address => uint256)) private userLpBalances; // asset => account => lp amount

    mapping(address => uint256) private bufferBalances; // asset => balance
    mapping(address => uint256) private lastPaid; // asset => timestamp
    mapping(address => uint256) public currentEpochRemainingBuffer; // asset => buffer amount

    mapping(address => bool) public whitelistedKeepers;
    mapping(address => bool) public whitelistedDepositer;
    mapping(address => bool) public whitelistedFundingAccount;
    mapping(address => int256) private globalUPLs; // asset => upl
    
    mapping(address => uint256) public feeReserves;  //treasury fees

    // Contracts
    AddressStorage public immutable addressStorage;
    PositionManager public positionManager;
    address public orderBookAddress;
    address public executorAddress;

        // Events
    event PoolDeposit(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 feeAmount,
        uint256 lpAmount,
        uint256 poolBalance
    );

    event DirectPoolDeposit(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 bufferToPoolAmount,
        uint256 poolBalance,
        uint256 bufferBalance
    );

    event PoolWithdrawal(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 feeAmount,
        uint256 lpAmount,
        uint256 poolBalance
    );

    event PoolPayIn(
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 amount,
        uint256 bufferToPoolAmount,
        uint256 poolBalance,
        uint256 bufferBalance
    );

    event PoolPayOut(
        address indexed user,
        address indexed asset,
        bytes10 market,
        uint256 amount,
        uint256 bufferToPoolAmount,
        uint256 poolBalance,
        uint256 bufferBalance
    );
    event FeeShareUpdated(uint256 feeShare);
    event BufferPayoutPeriodUpdated(uint256 period);
    event MaxLiquidityOrderTTLUpdated(uint256 maxLiquidityOrderTTL);    
    event UtilizationMultiplierUpdated(address indexed asset, uint256 utilizationMultiplier);
    event PublicDepositUpdated(bool isPublicDeposit);
    event WhitelistedKeeperUpdated(address indexed keeper, bool isActive);
    event WhitelistedFundingAccountUpdated(address indexed account, bool isActive);
    event WhitelistedDepositerUpdated(address indexed account, bool isActive);
    event Link(address orderBook, address positionManager, address executor);
    event WithdrawFees(address indexed asset, uint256 amount);
    event AssetSet(address indexed asset,Asset assetInfo);
    event MarketSet(bytes10 indexed market,Market marketInfo);
    event BalanceIncrement(address indexed asset, uint256 amount);
    event FeeAdded(address indexed asset, uint256 amount);
    event GlobalUPLSet(address indexed asset, int256 upl);
    event TransferIn(address indexed asset, address indexed from, uint256 amount);
    event TransferOut(address indexed asset, address indexed to, uint256 amount);
    event BufferToPool(address indexed asset,uint256 lastPaid,uint256 amountToSendPool);
    event AddOrder(uint32 indexed orderId, LiquidityType orderType);
    event RemoveOrder(uint32 indexed orderId, LiquidityType orderType);
    event OrderCancelled(uint32 indexed orderId, address indexed user, address executionFeeReceiver, string reason);
    event OrderCreated(
        uint32 indexed liquidityOrderId,
        address indexed user,
        address indexed asset,
        LiquidityType orderType,
        uint256 amount,
        uint256 minAmountMinusTax,
        uint256 executionFee,
        address fundingAccount
    );
    event OrderSkipped(uint32 indexed orderId, string reason);
    event OrderExecuted(uint32 indexed orderId, address indexed keeper, uint256 executionFee);
    event OrderExecutionFeeUpdated(uint64 orderExecutionFee);

    error Unauthorized(address account);

    

    /// @dev Only callable by PositionManager contract
    modifier onlyPositionManager() {
        if(msg.sender != address(positionManager))
            revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Only callable by PositionManager or Executor contracts
    modifier onlyPositionManagerAndExecutor() {
        if(msg.sender != address(positionManager) && msg.sender != executorAddress)
            revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Only callable by PositionManager or OrderBook contracts
    modifier onlyPositionManagerAndOrderBook() {
        if(msg.sender != address(positionManager) && msg.sender != orderBookAddress)
            revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Initializes addressStorage address
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        orderBookAddress = addressStorage.getAddress('OrderBook');
        positionManager = PositionManager(addressStorage.getAddress('PositionManager'));
        executorAddress = addressStorage.getAddress('Executor');
        emit Link(orderBookAddress, address(positionManager), executorAddress);
    }

    /// @notice withdraw treasury fees
    /// @dev Only callable by governance
    /// @param _asset  address of asset
    function withdrawFees(address _asset) external override onlyGov {
        uint256 amount = feeReserves[_asset];
        if (amount == 0) {
            return;
        }
        feeReserves[_asset] = 0;
        _transferOut(_asset, addressStorage.getAddress('treasury'), amount);
        emit WithdrawFees(_asset, amount);
    }

    /// @notice Set or update an asset
    /// @dev Only callable by governance
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _assetInfo Struct containing minSize and referencePriceFeed
    function setAsset(address _asset, Asset memory _assetInfo) external override onlyGov {
        assets[_asset] = _assetInfo;
        emit AssetSet(_asset, _assetInfo); 

        uint256 length = assetList.length;
        for (uint256 i; i < length; i++) {
            if (assetList[i] == _asset) return;
        }
        assetList.push(_asset);
        
    }

    /// @notice Set or update a market
    /// @dev Only callable by governance
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _marketInfo Market struct containing required market data
    function setMarket(bytes10 _market, Market memory _marketInfo) external override onlyGov {
        require(_marketInfo.fee <= MAX_FEE, '!max-fee');
        require(_marketInfo.maxLeverage >= 1, '!max-leverage');
        require(_marketInfo.maxDeviation <= MAX_DEVIATION, '!max-deviation');
        require(_marketInfo.liqThreshold <= MAX_LIQTHRESHOLD, '!max-liqthreshold');
        require(_marketInfo.minOrderAge <= MAX_MIN_ORDER_AGE, '!max-minorderage');
        require(_marketInfo.priceMaxAge >= MIN_MAX_AGE, '!min-pricemaxage');
        require(_marketInfo.priceSpread <= MAX_PRICE_SPREAD, '!max-pricespread');

        markets[_market] = _marketInfo;
        emit MarketSet(_market, _marketInfo);

        uint256 length = marketList.length;
        for (uint256 i; i < length; i++) {
            // check if _market already exists, if yes return
            if (marketList[i] == _market) return;
        }
        marketList.push(_market);

        
    }

    /// @notice Set store fee
    /// @dev Only callable by governance
    /// @param _bps fee share in bps
    function setFeeShare(uint256 _bps) external override onlyGov {
        require(_bps < BPS_DIVIDER, '!bps');
        feeShare = _bps;
        emit FeeShareUpdated(_bps);
    }

    /// @notice Set buffer payout period
    /// @dev Only callable by governance
    /// @param _period Buffer payout period in seconds, default is 7 days (604800 seconds)
    function setBufferPayoutPeriod(uint256 _period) external override onlyGov {
        require(_period > 0, '!min-period');
        require(_period <= MAX_BUFFER_PAYOUT_PERIOD, '!max-period');
        bufferPayoutPeriod = _period;
        emit BufferPayoutPeriodUpdated(_period);
    }

    /// @notice Set utilization multiplier
    /// @dev Only callable by governance
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _utilizationMultiplier utilization multiplier in bps ,e.g. if it is 5000 , maxOI available = asset balance x %50, it can be greater than bps according to use
    function setUtilizationMultiplier(address _asset, uint256 _utilizationMultiplier) external override onlyGov {
        require(_utilizationMultiplier > 0, '!min-utilization-multiplier');
        utilizationMultipliers[_asset] = _utilizationMultiplier;
        emit UtilizationMultiplierUpdated(_asset,_utilizationMultiplier);
    }

    /// @notice Set buffer payout period
    /// @dev Only callable by governance
    /// @param _maxLiquidityOrderTTL Buffer payout period in seconds, default is 7 days (604800 seconds)
    function setMaxLiquidityOrderTTL(uint256 _maxLiquidityOrderTTL) external override onlyGov {
        require(_maxLiquidityOrderTTL > 0, '!min-order-ttl');
        require(_maxLiquidityOrderTTL <= 1 hours, '!max-order-ttl');
        maxLiquidityOrderTTL = _maxLiquidityOrderTTL;
        emit MaxLiquidityOrderTTLUpdated(_maxLiquidityOrderTTL);
    }

    /// @notice Set depositing public or private
    /// @dev Only callable by governance
    /// @param _isPublicDeposit whether depositin is public
    function setIsPublicDeposit(bool _isPublicDeposit) external override onlyGov {
        isPublicDeposit = _isPublicDeposit;
        emit PublicDepositUpdated(_isPublicDeposit);
    }

    /// @notice Whitelisted keeper that can set global upl
    /// @dev Only callable by governance
    /// @param _keeper Keeper address
    /// @param _isActive whether keeper is active
    function setWhitelistedKeeper(address _keeper, bool _isActive) external  onlyGov {
        whitelistedKeepers[_keeper] = _isActive;
        emit WhitelistedKeeperUpdated(_keeper,_isActive); 
    }

    /// @notice Set whitelisted Funding Account
    /// @dev Only callable by governance
    /// @param _account  accounts authorized to deposit on behalf of another user
    /// @param _isActive whether account is active
    function setWhitelistedFundingAccount(address _account, bool _isActive) external  onlyGov {
        whitelistedFundingAccount[_account] = _isActive;
        emit WhitelistedFundingAccountUpdated(_account,_isActive);
    }

    /// @notice Set whitelisted depositer
    /// @dev Only callable by governance
    /// @param _account  accounts authorized to deposit
    /// @param _isActive whether account is active
    function setWhitelistedDepositer(address _account, bool _isActive) external override onlyGov {
        whitelistedDepositer[_account] = _isActive;
        emit WhitelistedDepositerUpdated(_account,_isActive);
    }

    /// @notice Set keeper gas fee for order execution 
    /// @dev Only callable by governance
    /// @param _orderExecutionFee Fee with native token e.g. ETH
    function setOrderExecutionFee(uint64 _orderExecutionFee) external onlyGov {
        orderExecutionFee = _orderExecutionFee;
        emit OrderExecutionFeeUpdated(_orderExecutionFee);
    }


    /// @notice Increments pool balance
    /// @dev Only callable by PositionManager contract
    function incrementBalance(address _asset, uint256 _amount) external onlyPositionManager {
        balances[_asset] += _amount;
        emit BalanceIncrement(_asset, _amount);
    }

    /// @notice Increments treasury fees
    /// @dev Only callable by PositionManager contract
    function addFees(address _asset, uint256 _amount) external onlyPositionManager {
        feeReserves[_asset] += _amount;
        emit FeeAdded(_asset, _amount);
    }

    /// @notice Set global UPL, called by whitelisted keeper
    /// @param _assets Asset addresses
    /// @param _upls Corresponding total unrealized profit / loss
    function setGlobalUPLs(address[] calldata _assets, int256[] calldata _upls) external {
        if(!whitelistedKeepers[msg.sender])
            revert Unauthorized(msg.sender);
        _setGlobalUPLs(_assets, _upls);    
    }

    /// @notice Set global UPL, called by whitelisted keeper
    /// @param _assets Asset addresses
    /// @param _upls Corresponding total unrealized profit / loss
    function _setGlobalUPLs(address[] memory _assets, int256[] memory _upls) internal {
        for (uint256 i; i < _assets.length; i++) {
            globalUPLs[_assets[i]] = _upls[i];
            emit GlobalUPLSet(_assets[i], _upls[i]);
        }
    }


    /// @notice Credit trader loss to buffer and pay pool from buffer amount based on time and payout rate
    /// @dev Only callable by PositionManager and Executor contracts
    /// @param _user User which incurred trading loss
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _amount Amount of trader loss
    function creditTraderLoss(address _user, address _asset, bytes10 _market, uint256 _amount) external onlyPositionManagerAndExecutor {

        // pending buffer transfer to the pool
        uint256 amountToSendPool = _sendBufferToPool(_asset);

        // credit trader loss to buffer
        _incrementBufferBalance(_asset, _amount);

        // emit event
        emit PoolPayIn(
            _user,
            _asset,
            _market,
            _amount,
            amountToSendPool,
            balances[_asset],
            bufferBalances[_asset]
        );
    }

    /// @notice Pay out trader profit, from buffer first then pool if buffer is depleted
    /// @dev Only callable by PositionManager contract
    /// @param _user Address to send funds to
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    /// @param _amount Amount of trader profit
    function debitTraderProfit(
        address _user,
        address _asset,
        bytes10 _market,
        uint256 _amount
    ) external onlyPositionManager {
        // return if profit = 0
        if (_amount == 0) return;

        uint256 bufferBalance = bufferBalances[_asset];

        // decrement buffer balance first
        _decrementBufferBalance(_asset, _amount);

        // decrement first next epoch buffer then current epoch remaining
        // if new buffer less than currentEpochRemaining, reduce currentEpochRemaining to buffer.
        if(bufferBalance  < currentEpochRemainingBuffer[_asset] + _amount) {
            currentEpochRemainingBuffer[_asset] = bufferBalances[_asset];
        }

        // if _amount is greater than available in the buffer, pay remaining from the pool
        if (_amount > bufferBalance) {
            uint256 diffToPayFromPool = _amount - bufferBalance;
            uint256 poolBalance = balances[_asset];
            require(diffToPayFromPool < poolBalance, '!pool-balance');
            _decrementBalance(_asset, diffToPayFromPool);
        }

        // pending buffer transfer to the pool
        uint256 amountToSendPool = _sendBufferToPool(_asset);

        // transfer profit out
        _transferOut(_asset, _user, _amount);

        // emit event
        emit PoolPayOut(_user, _asset, _market, _amount, amountToSendPool, balances[_asset], bufferBalances[_asset]);
    }

    /// @notice Transfers `_amount` of `_asset` in
    /// @dev Only callable by PositionManager or OrderBook contracts
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _from Address where asset is transferred from
    function transferIn(address _asset, address _from, uint256 _amount) external payable onlyPositionManagerAndOrderBook {
        _transferIn(_asset,_from,_amount);
    }

    /// @notice Transfers `_amount` of `_asset` out
    /// @dev Only callable by PositionManager or OrderBook contracts
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _to Address where asset is transferred to
    function transferOut(address _asset, address _to, uint256 _amount) external nonReentrant onlyPositionManagerAndOrderBook {
        _transferOut(_asset,_to,_amount);
    }

    /// @notice Direct Pool Deposit `_amount` of `_asset` into the pool via buffer
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _amount Amount to be deposited
    function directPoolDeposit(address _asset, uint256 _amount) external payable {
        require(_amount > 0, '!_amount');
        require(isSupported(_asset), '!_asset');

        // if _asset is ETH (address(0)), set _amount to msg.value
        if (_asset == address(0)) {
            require(msg.value > 0, '!msg.value');
            _amount = msg.value;
        } else {
            _transferIn(_asset, msg.sender, _amount);
        }

        // first the pending buffer will be transferred to the pool
        uint256 amountToSendPool = _sendBufferToPool(_asset);

        // direct deposit to buffer
        _incrementBufferBalance(_asset, _amount);

        // emit event
        emit DirectPoolDeposit(
            msg.sender, 
            _asset, 
            _amount, 
            amountToSendPool,
            balances[_asset],
            bufferBalances[_asset]
        );
    }    

    /// @notice Cancels order
    /// @param _orderId Order to cancel
    function cancelOrder(uint32 _orderId) external  {
        LiquidityOrder memory order = liquidityOrders[_orderId];
        require(order.amount > 0, '!order');
        require(order.user == msg.sender, '!user');
        _cancelOrder(_orderId, 'by-user', msg.sender);
    }

    /// @notice Submits a new deposit order
    /// @param _params Liquidity order to submit
    function depositRequest(
        LiquidityOrder memory _params
    ) external payable {
        if(!isPublicDeposit){
            require(whitelistedDepositer[msg.sender], '!whitelisted');
        }      
        require(_params.amount > 0, '!_amount');
        require(_params.amount >= _params.minAmountMinusTax, '!min-amount');
        require(isSupported(_params.asset), '!_asset');

        _params.user = _orderUser(_params);
        _params.orderType = LiquidityType.DEPOSIT;
        _params.timestamp = block.timestamp.toUint32();
        _params.executionFee = orderExecutionFee;

        // if _asset is ETH (address(0)), msg.value must be equal to amount + execution fee
        if (_params.asset == address(0)) {
            require(msg.value == _params.amount + _params.executionFee, '!msg.value');
        } else {
            require(msg.value == _params.executionFee, '!msg.value');
            _transferIn(_params.asset, msg.sender, _params.amount);
        }

        // Add order to store and emit event
        _params.liquidityOrderId = _add(_params);

        emit OrderCreated(
            _params.liquidityOrderId,
            _params.user,
            _params.asset,
            _params.orderType,
            _params.amount,
            _params.minAmountMinusTax,
            _params.executionFee,
            msg.sender
        );
    }

    /// @notice Submits a new withdraw order
    /// @param _params Liquidity order to submit
    function withdrawRequest(
        LiquidityOrder memory _params
    ) external payable {
        require(_params.amount > 0, '!_amount');
        require(msg.value == orderExecutionFee, '!msg.value');
        require(isSupported(_params.asset), '!_asset');

        _params.user = msg.sender;
        _params.orderType = LiquidityType.WITHDRAW;
        _params.timestamp = block.timestamp.toUint32();
        _params.executionFee = orderExecutionFee;

        // check pool balance and lp supply
        uint256 balance = balances[_params.asset];
        uint256 lpAssetSupply = lpSupply[_params.asset];
        require(balance > 0 && lpAssetSupply > 0, '!empty');

        // check user balance
        uint256 userBalance = getUserBalance(_params.asset, _params.user);
        if (_params.amount > userBalance) _params.amount = userBalance.toUint96();

        require(_params.amount >= _params.minAmountMinusTax, '!min-amount');

        // check available liquidity for open interests
        // if utilizationMultiplier is defined less than BPS_DIVIDER, allow user to withdraw with 1:1 ratio
        uint256 utilizationMultiplier = utilizationMultipliers[_params.asset];
        if(utilizationMultiplier < BPS_DIVIDER) utilizationMultiplier = BPS_DIVIDER;  
        require(positionManager.getAssetOI(_params.asset) <= (getAvailable(_params.asset) - _params.amount) * utilizationMultiplier / BPS_DIVIDER,"!not-available-liquidity");        

        // Add order to store and emit event
        _params.liquidityOrderId = _add(_params);

        emit OrderCreated(
            _params.liquidityOrderId,
            _params.user,
            _params.asset,
            _params.orderType,
            _params.amount,
            _params.minAmountMinusTax,
            _params.executionFee,
            address(0)
        );
    }

     /// @notice Order execution by keeper with global upls
    /// @dev Only callable by whitelistedKeepers
    /// @param _orderIds order id's to execute
    /// @param _assets Array of Asset
    /// @param _upls Array of Asset upls
    function executeOrders(
        uint32[] calldata _orderIds,
        address[] calldata _assets, 
        int256[] calldata _upls
    ) external nonReentrant {
        if(!whitelistedKeepers[msg.sender])
            revert Unauthorized(msg.sender);

        _setGlobalUPLs(_assets,_upls);

        for (uint256 i; i < _assets.length; i++) {
            // pending buffer transfer to the pool
            _sendBufferToPool(_assets[i]);         
        }

        for (uint256 i; i < _orderIds.length; i++) {
            (bool status, string memory reason) = _executeOrder(_orderIds[i], msg.sender);
            if (!status) _cancelOrder(_orderIds[i], reason, msg.sender);            
        }

    }

    /// @notice Returns asset struct of `_asset`
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getAsset(address _asset) external view returns (Asset memory) {
        return assets[_asset];
    }

    /// @notice Get a list of all supported assets
    function getAssetList() external view returns (address[] memory) {
        return assetList;
    }

    /// @notice Get number of supported assets
    function getAssetCount() external view returns (uint256) {
        return assetList.length;
    }

    /// @notice Returns asset address at `_index`
    /// @param _index index of asset
    function getAssetByIndex(uint256 _index) external view returns (address) {
        return assetList[_index];
    }

    /// @notice Returns market struct of `market`
    /// @param _market Market, e.g. "0x4554482D555344000000" is bytes10 equivalent of "ETH-USD" 
    function getMarket(bytes10 _market) external view override returns (Market memory) {
        return markets[_market];
    }

    /// @notice Returns market struct array of specified markets
    /// @param _markets Array of market bytes10, e.g. ["0x4554482D555344000000", "0x4254432D555344000000"] for ETH-USD and BTC-USD
    function getMarketMany(bytes10[] calldata _markets) external view returns (Market[] memory) {
        uint256 length = _markets.length;
        Market[] memory _marketInfos = new Market[](length);
        for (uint256 i; i < length; i++) {
            _marketInfos[i] = markets[_markets[i]];
        }
        return _marketInfos;
    }

    /// @notice Returns market identifier at `index`
    /// @param index index of marketList
    function getMarketByIndex(uint256 index) external view returns (bytes10) {
        return marketList[index];
    }

    /// @notice Get a list of all supported markets
    function getMarketList() external view returns (bytes10[] memory) {
        return marketList;
    }

    /// @notice Get number of supported markets
    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }

    /// @notice Returns the sum of buffer and pool balance of `_asset`
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getAvailable(address _asset) public view returns (uint256) {
        return balances[_asset] + bufferBalances[_asset];
    }

    /// @notice Returns the sum of buffer and pool balance of `_asset` multiplied by utilization multiplier
    /// @dev For available OI control for new position
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getAvailableForOI(address _asset) external view returns (uint256) {
        return ((balances[_asset] + bufferBalances[_asset]) * utilizationMultipliers[_asset]) / BPS_DIVIDER;
    }

    
    /// @notice Returns amount of `_asset` in pool
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getBalance(address _asset) external view returns (uint256) {
        return balances[_asset];
    }

    /// @notice Returns pool balances of `_assets`
    function getBalances(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i; i < length; i++) {
            _balances[i] = balances[_assets[i]];
        }

        return _balances;
    }

    /// @notice Returns buffer balances of `_assets`
    function getBufferBalances(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i; i < length; i++) {
            _balances[i] = bufferBalances[_assets[i]];
        }

        return _balances;
    }

    /// @notice Returns `_assets` balance of `account`
    function getUserBalances(address[] calldata _assets, address account) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i; i < length; i++) {
            _balances[i] = getUserBalance(_assets[i], account);
        }

        return _balances;
    }

    /// @notice Returns last time pool was paid
    /// @param _asset Asset address, e.g. address(0) for ETH
    function getLastPaid(address _asset) external view returns (uint256) {
        return lastPaid[_asset];
    }

    /// @notice Returns total amount of LP for `_asset`
    function getLpSupply(address _asset) external view returns (uint256) {
        return lpSupply[_asset];
    }

    /// @notice Returns total unrealized p/l for `_asset`
    function getGlobalUPL(address _asset) external view returns (int256) {
        return globalUPLs[_asset];
    }

        /// @notice Returns liquidity orders
    /// @param _length Amount of liquidity orders to return
    function getLiquidityOrders(uint256 _length) external view returns (LiquidityOrder[] memory) {
        uint32 orderlength = liquidityOrderIds.length().toUint32();
        if (_length > orderlength) _length = orderlength;

        LiquidityOrder[] memory _orders = new LiquidityOrder[](_length);

        for (uint256 i; i < _length; i++) {
            _orders[i] = liquidityOrders[liquidityOrderIds.at(i).toUint32()];
        }

        return _orders;
    }

    /// @notice Returns orders of `user`    
    function getUserOrders(address _user) external view returns (LiquidityOrder[] memory) {
        uint32 length = userLiquidityOrderIds[_user].length().toUint32();
        LiquidityOrder[] memory _orders = new LiquidityOrder[](length);

        for (uint256 i; i < length; i++) {
            _orders[i] = liquidityOrders[userLiquidityOrderIds[_user].at(i).toUint32()];
        }

        return _orders;
    }

    /// @notice Returns amount of market orders
    function getLiquidityOrderCount() external view returns (uint256) {
        return liquidityOrderIds.length();
    }

    /// @notice Returns order amount of `user`
    function getUserOrderCount(address _user) external view returns (uint256) {
        return userLiquidityOrderIds[_user].length();
    }

    /// @notice Get order user 
    /// @dev if sender is whitelisted funding account and order is suitable, The user is being made incoming in the params 
    /// @param _params Order params
    /// @return user order user
    function _orderUser(LiquidityOrder memory _params) internal view returns (address) {
        if(whitelistedFundingAccount[msg.sender]){
            require(_params.user != address(0) ,"funding-account-order-fail");
            return _params.user;        
        }
        return msg.sender;
    }

    /// @notice Returns pool deposit tax for `asset` and amount in bps
    function getDepositTaxBps(address _asset, uint256 _amount) public view returns (uint256) {
        uint256 taxBps;
        uint256 balance = balances[_asset];
        uint256 bufferBalance = bufferBalances[_asset];
        if (globalUPLs[_asset] - int256(bufferBalance) < 0) {
            taxBps = uint256(int256(BPS_DIVIDER) * (int256(bufferBalance) - globalUPLs[_asset]) / (int256(balance) + int256(_amount)));
        }
        return taxBps;
    }

    /// @notice Returns pool withdrawal tax for `asset` and amount in bps
    function getWithdrawalTaxBps(address _asset, uint256 _amount) public view returns (uint256) {
        uint256 taxBps;
        uint256 balance = balances[_asset];
        if (_amount > balance) return BPS_DIVIDER;
        uint256 bufferBalance = bufferBalances[_asset];
        if (globalUPLs[_asset] - int256(bufferBalance) > 0 ) {  
            if(_amount < balance)
                taxBps = uint256(int256(BPS_DIVIDER) * (globalUPLs[_asset] - int256(bufferBalance)) / (int256(balance) - int256(_amount)));
            else // _amount = balance => in fact if there is an open position, the last depositor cannot withdraw the entire balance, so this will not happen, but it may remain as a calculation 
                taxBps = uint256(int256(BPS_DIVIDER) * (globalUPLs[_asset] - int256(bufferBalance)) / int256(_amount));

        }
        return taxBps;
    }

    /// @notice Returns `_asset` balance of `_account`
    function getUserBalance(address _asset, address _account) public view returns (uint256) {
        if (lpSupply[_asset] == 0) return 0;
        return (userLpBalances[_asset][_account] * balances[_asset]) / lpSupply[_asset];
    }

    /// @notice Returns amount of LP of `_account` for `_asset`
    function getUserLpBalance(address _asset, address _account) external view returns (uint256) {
        return userLpBalances[_asset][_account];
    }

    /// @notice Returns true if `_asset` is supported
    /// @param _asset Asset address, e.g. address(0) for ETH
    function isSupported(address _asset) public view returns (bool) {
        return assets[_asset].minSize > 0;
    }

    /// @notice Returns amount of `_asset` in buffer
    function getBufferBalance(address _asset) external view returns (uint256) {
        return bufferBalances[_asset];
    }

    /// @notice Increments pool balance
    /// @dev Internal function
    function _incrementBalance(address _asset, uint256 _amount) internal {
        balances[_asset] += _amount;
    }

    /// @notice Decrements pool balance
    /// @dev Internal function
    function _decrementBalance(address _asset, uint256 _amount) internal {
        balances[_asset] = balances[_asset] <= _amount ? 0 : balances[_asset] - _amount;
    }

    /// @notice  Increments buffer balance
    /// @dev Internal function
    function _incrementBufferBalance(address _asset, uint256 _amount) internal {
        bufferBalances[_asset] += _amount;
    }

    /// @notice  Decrements buffer balance
    /// @dev Internal function
    function _decrementBufferBalance(address _asset, uint256 _amount) internal {
        bufferBalances[_asset] = bufferBalances[_asset] <= _amount ? 0 : bufferBalances[_asset] - _amount;
    }

    /// @notice  Updates `lastPaid`
    /// @dev Internal function
    function _setLastPaid(address _asset, uint256 _timestamp) internal {
        lastPaid[_asset] = _timestamp;
    }

    /// @notice Increments `lpSupply` and `userLpBalances`
    /// @dev Internal function
    function _incrementUserLpBalance(address _asset, address _user, uint256 _amount) internal {
        lpSupply[_asset] += _amount;

        unchecked {
            // Overflow not possible: balance + _amount is at most lpSupply + _amount, which is checked above.
            userLpBalances[_asset][_user] += _amount;
        }
    }

    /// @notice Decrements `lpSupply` and `userLpBalances`
    /// @dev Internal function
    function _decrementUserLpBalance(address asset, address _user, uint256 amount) internal {
        lpSupply[asset] = lpSupply[asset] <= amount ? 0 : lpSupply[asset] - amount;

        userLpBalances[asset][_user] = userLpBalances[asset][_user] <= amount
            ? 0
            : userLpBalances[asset][_user] - amount;
    }

    /// @notice Stream buffer balance progressively into the pool
    /// @dev Internal function
    function _sendBufferToPool(address _asset) internal returns (uint256) {
        // local variables
        uint256 bufferBalance = bufferBalances[_asset];
        uint256 lpAsset = lastPaid[_asset];
        uint256 currentTimestamp = block.timestamp;
        uint256 amountToSendPool;

        if(bufferBalance > 0 ){
            
            uint256 currentEpochStart = currentTimestamp / bufferPayoutPeriod * bufferPayoutPeriod;
            uint256 currentEpochRemaining = currentEpochRemainingBuffer[_asset];


            if(lpAsset < currentEpochStart - bufferPayoutPeriod){ // if the last transfer is before 2 periods, all buffer must be transferred
                amountToSendPool = bufferBalance;
                currentEpochRemaining = 0; 
            }else{
                if(lpAsset < currentEpochStart){   // previous epoch remaining         
                    amountToSendPool = currentEpochRemaining;
                    currentEpochRemaining = bufferBalance - amountToSendPool ;  //new epoch buffer amount
                    lpAsset = currentEpochStart;
                }

                if(currentEpochRemaining > 0 ){ 
                    uint256 transferAmount = currentEpochRemaining * (currentTimestamp - lpAsset) / (currentEpochStart + bufferPayoutPeriod - lpAsset);
                    if(transferAmount > currentEpochRemaining) transferAmount = currentEpochRemaining;
                    amountToSendPool += transferAmount;
                    currentEpochRemaining -= transferAmount;  
                }

                if (amountToSendPool >= bufferBalance) { //if true,  currentEpochRemainingBuffer must be empty
                    amountToSendPool = bufferBalance;
                    currentEpochRemaining = 0; 
                }    
            }

            currentEpochRemainingBuffer[_asset] = currentEpochRemaining;

            // update storage
            if(amountToSendPool > 0){
                _incrementBalance(_asset, amountToSendPool);
                _decrementBufferBalance(_asset, amountToSendPool);
            }        


        }

        _setLastPaid(_asset, currentTimestamp);

        emit BufferToPool(_asset, currentTimestamp, amountToSendPool);

        return amountToSendPool;
    }

    /// @notice Transfers `_amount` of `_asset` in
    /// @dev Internal function
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _from Address where asset is transferred from
    function _transferIn(address _asset, address _from, uint256 _amount) internal {
        if (_amount == 0 || _asset == address(0)) return;
        IERC20(_asset).safeTransferFrom(_from, address(this), _amount);
        emit TransferIn(_asset, _from, _amount);
    }

    /// @notice Transfers `_amount` of `_asset` out
    /// @dev Internal function
    /// @param _asset Asset address, e.g. address(0) for ETH
    /// @param _to Address where asset is transferred to
    function _transferOut(address _asset, address _to, uint256 _amount) internal{
        if (_amount == 0 || _to == address(0)) return;
        if (_asset == address(0)) {
            payable(_to).sendValue(_amount);
        } else {
            IERC20(_asset).safeTransfer(_to, _amount);
        }
        emit TransferOut(_asset, _to, _amount);
    }

        /// @dev Executes submitted order
    /// @param _orderId Order to execute
    /// @param _keeper keeper address
    /// @return status if true, order is not canceled.
    /// @return message if not blank, includes order revert message.
    function _executeOrder(
        uint32 _orderId,
        address _keeper
    ) internal returns (bool, string memory) { 
        LiquidityOrder memory order = liquidityOrders[_orderId];

        if (order.amount == 0) {
            return (false, '!order');
        }

        if (order.timestamp + maxLiquidityOrderTTL < block.timestamp ) {
            return (false, '!expired');
        } 
        
        if(order.orderType == LiquidityType.DEPOSIT ){  
            uint256 taxBps = getDepositTaxBps(order.asset, order.amount);
            if(taxBps >= BPS_DIVIDER){
                return (false, '!tax');
            }

            uint256 tax = (order.amount * taxBps) / BPS_DIVIDER;
            uint256 amountMinusTax = order.amount - tax;
            if(amountMinusTax < order.minAmountMinusTax){
                return(false, '!min-amount');
            }

            // pool share is equal to pool balance of _user divided by the total balance
            uint256 balance = balances[order.asset];
            uint256 lpAssetSupply = lpSupply[order.asset];
            uint256 lpAmount = balance == 0 || lpAssetSupply == 0 ? amountMinusTax : (amountMinusTax * lpAssetSupply) / balance;

            // increment balances
            _incrementUserLpBalance(order.asset, order.user, lpAmount);
            _incrementBalance(order.asset, order.amount);

            // emit event
            emit PoolDeposit(order.user, order.asset, order.amount, tax, lpAmount, balances[order.asset]);               

        } else if(order.orderType == LiquidityType.WITHDRAW ){
            // check user balance
            uint256 userBalance = getUserBalance(order.asset, order.user);
            if (order.amount > userBalance) order.amount = userBalance.toUint96();
            if(order.amount == 0) {
                return (false, '!zero-amount');
            }

            // check available liquidity for open interests
            // if utilizationMultiplier is defined less than BPS_DIVIDER, allow user to withdraw with 1:1 ratio
            uint256 utilizationMultiplier = utilizationMultipliers[order.asset];
            if(utilizationMultiplier < BPS_DIVIDER) utilizationMultiplier = BPS_DIVIDER;  

            if((getAvailable(order.asset) - order.amount) * utilizationMultiplier / BPS_DIVIDER < positionManager.getAssetOI(order.asset)){
                return (false, '!not-available-liquidity');
            }

            // withdrawal tax
            uint256 taxBps = getWithdrawalTaxBps(order.asset, order.amount);
            if(taxBps >= BPS_DIVIDER){
                return (false, '!tax');
            }
            uint256 tax = (order.amount * taxBps) / BPS_DIVIDER;
            uint256 amountMinusTax = order.amount - tax;
            if(amountMinusTax < order.minAmountMinusTax){
                return(false, '!min-amount');
            }

            // LP amount
            uint256 balance = balances[order.asset];
            uint256 lpAssetSupply = lpSupply[order.asset];
            uint256 lpAmount = (order.amount * lpAssetSupply) / balance;

            // decrement balances
            _decrementUserLpBalance(order.asset, order.user, lpAmount);
            _decrementBalance(order.asset, amountMinusTax);

            // transfer funds out
            _transferOut(order.asset, order.user, amountMinusTax);

            // emit event
            emit PoolWithdrawal(order.user, order.asset, order.amount, tax, lpAmount, balances[order.asset]);             

        }
        _remove(_orderId);
        if(order.executionFee > 0){
            _transferOut(address(0), _keeper, order.executionFee);
        }
        emit OrderExecuted(_orderId, _keeper, order.executionFee);
        return (true, '');
    }    

    /// @notice  Adds order to storage
    /// @dev Internal function
    function _add(LiquidityOrder memory _order) internal returns (uint32) {
        uint32 nextOrderId = ++liquidityOid;
        _order.liquidityOrderId = nextOrderId;
        liquidityOrders[nextOrderId] = _order;
        userLiquidityOrderIds[_order.user].add(nextOrderId);
        liquidityOrderIds.add(nextOrderId);

        emit AddOrder(nextOrderId, _order.orderType);

        return nextOrderId;
    }

    /// @notice  Removes order from store
    /// @dev Internal function
    /// @param _orderId Order to remove
    function _remove(uint32 _orderId) internal {
        LiquidityOrder memory order = liquidityOrders[_orderId];
        if (order.amount == 0) return;
        userLiquidityOrderIds[order.user].remove(_orderId);
        liquidityOrderIds.remove(_orderId);
        emit RemoveOrder(_orderId, order.orderType);
        delete liquidityOrders[_orderId];        
    }



    /// @notice Cancels order
    /// @dev Internal function without access restriction
    /// @param _orderId Order to cancel
    /// @param _reason Cancellation reason
    /// @param _executionFeeReceiver Address of execution fee receiver
    function _cancelOrder(uint32 _orderId, string memory _reason, address _executionFeeReceiver) internal {
        LiquidityOrder memory order = liquidityOrders[_orderId];
        if (order.amount == 0) return;
        _remove(_orderId);

        bool isSentNative;

        if (order.orderType == LiquidityType.DEPOSIT) {
            isSentNative = order.asset == address(0) && order.user == _executionFeeReceiver;
            _transferOut(order.asset, order.user, order.amount + (isSentNative ? order.executionFee : 0));
        }

        if(order.executionFee > 0 && !isSentNative){
            _transferOut(address(0), _executionFeeReceiver, order.executionFee);
        }

        emit OrderCancelled(_orderId, order.user, _executionFeeReceiver, _reason);
    }

    // /// @dev functionCall 
    function functionCall(
        address target,
        bytes memory data
    )
        external
        onlyGov
    {

        require(target != address(0),"!target is empty");
        uint256[] memory beforeBalances = new uint256[](assetList.length);
        for (uint256 i = 0; i < assetList.length; i++) {
            if(assetList[i] == address(0)){
                beforeBalances[i] = address(this).balance;
            }else{
                beforeBalances[i] = IERC20(assetList[i]).balanceOf(address(this));
            }
            
        }

        bytes4 functionSel;
        bytes4 x = bytes4(0xff000000);
        functionSel ^= (x & data[0]);
        functionSel ^= (x & data[1]) >> 8;
        functionSel ^= (x & data[2]) >> 16;
        functionSel ^= (x & data[3]) >> 24;

        if(functionSel != 0xdc4fcda7 )  // ignore batchDelegate function For FTSO Provider Delegation
            for (uint256 i = 0; i < assetList.length; i++) {
                if(target == assetList[i]){
                    revert("!asset address not allowed");
                }
                
            }      

        Address.functionCall(target, data);

        uint256[] memory afterBalances = new uint256[](assetList.length);
        for (uint256 i = 0; i < assetList.length; i++) {
            if(assetList[i] == address(0)){
                afterBalances[i] = address(this).balance;
            }else{
                afterBalances[i] = IERC20(assetList[i]).balanceOf(address(this));
            }
        }

        require(beforeBalances.length == afterBalances.length,"!assetlist not equal");
        for (uint256 i = 0; i < assetList.length; i++) {
            if(beforeBalances[i] > afterBalances[i]){
                revert("!asset balance decreased");
            }
        }        
    }

}

