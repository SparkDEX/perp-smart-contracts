// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import "./interfaces/ITimelockTarget.sol";
import "./interfaces/ITimelock.sol";
import "./interfaces/IAdmin.sol";
import "../interfaces/IReferralStorage.sol";
import './interfaces/IAddressStorage.sol';
import './interfaces/ILink.sol';
import './interfaces/ITradingValidator.sol';
import './interfaces/IWhitelistedKeeper.sol';
import './interfaces/IWhitelistedFundingAccount.sol';
import './interfaces/IFundingTracker.sol';
import './interfaces/IOrderBook.sol';
import './interfaces/IPositionManager.sol';
import './interfaces/IExecutor.sol';
import './interfaces/IStore.sol';
import './interfaces/IReferencePriceFeed.sol';


// @title Timelock
contract Timelock is ITimelock {

    uint256 public constant MIN_BUFFER = 1 hours;
    uint256 public constant MAX_BUFFER = 7 days;

    uint256 public buffer;
    uint256 public maxDuration = 7 days;
    address public admin;

    address public immutable tokenManager;

    mapping (bytes32 => uint256) public pendingActions;

    event SignalPendingAction(bytes32 action);
    event SignalSetAddress(address target, string key, address value, bool overwrite);
    event SignalSetAsset(address target, address asset, IStore.Asset assetinfo);
    event SignalSetMarket(address target, bytes10 market, IStore.Market marketInfo);
    event SignalSetGov(address target, address gov, bytes32 action);

    event ClearAction(bytes32 action);
    event AdminSet(address indexed admin);
    event ExternalAdminSet(address indexed target, address indexed admin);
    event BufferSet(uint256 buffer);
    event MaxDurationSet(uint256 maxDuration);
    event GovSet(address indexed target, address indexed gov);

    modifier onlyAdmin() {
        require(msg.sender == admin, "TL: forbidden");
        _;
    }

    modifier onlyTokenManager() {
        require(msg.sender == tokenManager, "TL: forbidden");
        _;
    }

    constructor(
        address _admin,
        uint256 _buffer,
        address _tokenManager
    ) {
        require(_admin != address(0), "TL: !admin zero address");
        require(_buffer >= MIN_BUFFER, "TL: invalid min _buffer");
        require(_buffer <= MAX_BUFFER, "TL: invalid max _buffer");
        require(_tokenManager != address(0), "TL: !tokenManager zero address");
        admin = _admin;
        buffer = _buffer;
        tokenManager = _tokenManager;        
    }

    function setAdmin(address _admin) external override onlyTokenManager {
        admin = _admin;
        emit AdminSet(_admin);
    }

    function setExternalAdmin(address _target, address _admin) external onlyAdmin {
        require(_target != address(this), "TL: invalid _target");
        IAdmin(_target).setAdmin(_admin);
        emit ExternalAdminSet(_target, _admin);
    }

    function setBuffer(uint256 _buffer) external onlyAdmin {
        require(_buffer <= MAX_BUFFER, "TL: invalid _buffer");
        require(_buffer > buffer, "TL: buffer cannot be decreased");
        buffer = _buffer;
        emit BufferSet(_buffer);
    }

    function setMaxDuration(uint256 _maxDuration) external onlyAdmin {
        require(_maxDuration <= MAX_BUFFER, "TL: invalid _maxDuration");
        maxDuration = _maxDuration;
        emit MaxDurationSet(_maxDuration);
    }
    

    function setTier(address _referralStorage, uint256 _tierId, uint256 _totalRebate, uint256 _discountShare) external onlyAdmin {
        IReferralStorage(_referralStorage).setTier(_tierId, _totalRebate, _discountShare);
    }

    function setReferrerTier(address _referralStorage, address _referrer, uint256 _tierId) external onlyAdmin {
        IReferralStorage(_referralStorage).setReferrerTier(_referrer, _tierId);
    }

    function govSetCodeOwner(address _referralStorage, bytes32 _code, address _newAccount) external onlyAdmin {
        IReferralStorage(_referralStorage).govSetCodeOwner(_code, _newAccount);
    }

    function signalSetGov(address _target, address _gov) external override onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _setPendingAction(action);
        emit SignalSetGov(_target, _gov, action);
    }

    function setGov(address _target, address _gov) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).setGov(_gov);
        emit GovSet(_target, _gov);
    }

    function signalSetAddress(address _target, string calldata _key, address _value, bool _overwrite) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setAddress", _target, _key, _value, _overwrite));
        _setPendingAction(action);
        emit SignalSetAddress(_target, _key, _value, _overwrite);
    }

    function setAddress(address _target, string calldata _key, address _value, bool _overwrite) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setAddress", _target, _key, _value, _overwrite));
        _validateAction(action);
        _clearAction(action);
        IAddressStorage(_target).setAddress(_key, _value, _overwrite);
    }

    function setLink(address _target) external onlyAdmin {
        ILink(_target).link();
    }

    function setMaxOI(address _target, bytes10 market, address asset, uint256 amount) external onlyAdmin {
        ITradingValidator(_target).setMaxOI(market, asset, amount);
    }
    function setMaxOIs(address _target, bytes10[] calldata markets, address[] calldata assets, uint256[] calldata amounts) external onlyAdmin {
        ITradingValidator(_target).setMaxOIs(markets, assets, amounts);
    }

    function setPoolHourlyDecay(address _target, uint256 bps) external onlyAdmin {
        ITradingValidator(_target).setPoolHourlyDecay(bps);
    }

    function setPoolProfitLimit(address _target, address asset, uint256 bps) external onlyAdmin {
        ITradingValidator(_target).setPoolProfitLimit(asset, bps);
    }
    
    function setWhitelistedKeeper(address _target, address keeper, bool isActive) external onlyAdmin {
        IWhitelistedKeeper(_target).setWhitelistedKeeper(keeper, isActive);
    }

    function setFundingInterval(address _target, uint256 interval) external onlyAdmin {
        IFundingTracker(_target).setFundingInterval(interval);
    }

    function setWhitelistedFundingAccount(address _target, address account, bool isActive) external onlyAdmin {
        IWhitelistedFundingAccount(_target).setWhitelistedFundingAccount(account, isActive);
    }

    function setAreNewOrdersPaused(address _target, bool b) external onlyAdmin {
        IOrderBook(_target).setAreNewOrdersPaused(b);
    }
    function setIsSelfExecutionActive(address _target, bool b) external onlyAdmin {
        IOrderBook(_target).setIsSelfExecutionActive(b);
    }
    function setIsProcessingPaused(address _target, bool b) external onlyAdmin {
        IOrderBook(_target).setIsProcessingPaused(b);
    }
    function setMaxMarketOrderTTL(address _target, uint256 amount) external onlyAdmin {
        IOrderBook(_target).setMaxMarketOrderTTL(amount);
    }
    function setMaxTriggerOrderTTL(address _target, uint256 amount) external onlyAdmin {
        IOrderBook(_target).setMaxTriggerOrderTTL(amount);
    }

    function setOrderExecutionFee(address _target, uint256 amount) external onlyAdmin {
        IOrderBook(_target).setOrderExecutionFee(amount);
    }

    function setEnableOrderByGov(address _target, address _account) external onlyAdmin {
        IOrderBook(_target).enableOrderByGov(_account);
    }

    function setEthSignedMessageHash(address _target, bytes32 _messageHash) external onlyAdmin {
        IOrderBook(_target).setEthSignedMessageHash(_messageHash);
    }

    function setMinPositionHoldTime(address _target, uint256 _minPositionHoldTime) external onlyAdmin {
        IPositionManager(_target).setMinPositionHoldTime(_minPositionHoldTime);
    }
    function setRemoveMarginBuffer(address _target, uint256 bps) external onlyAdmin {
        IPositionManager(_target).setRemoveMarginBuffer(bps);
    }
    function setKeeperFeeShare(address _target, uint256 bps) external onlyAdmin {
        IPositionManager(_target).setKeeperFeeShare(bps);
    }

    function setTrailingStopFee(address _target, uint256 bps) external onlyAdmin {
        IPositionManager(_target).setTrailingStopFee(bps);
    }

    function setLiquidationFee(address _target, uint256 bps) external onlyAdmin {
        IExecutor(_target).setLiquidationFee(bps);
    }

    function setIsReferencePriceMandatory(address _target, bool _mandatory) external onlyAdmin {
        IExecutor(_target).setIsReferencePriceMandatory(_mandatory);
    }

    function signalSetAsset(address _target, address asset, IStore.Asset memory assetInfo) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setAsset", _target, asset, assetInfo.decimals, assetInfo.minSize, assetInfo.priceFeedId));
        _setPendingAction(action);
        emit SignalSetAsset(_target, asset, assetInfo);
    }
    function setAsset(address _target, address asset, IStore.Asset memory assetInfo) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setAsset", _target, asset, assetInfo.decimals, assetInfo.minSize, assetInfo.priceFeedId));
        _validateAction(action);
        _clearAction(action);
        IStore(_target).setAsset(asset, assetInfo);
    }

    function signalSetMarket(address _target, bytes10 market, IStore.Market memory marketInfo) external onlyAdmin {
        bytes memory marketEncode = abi.encodePacked(
            marketInfo.name, // Market's full name, e.g. Bitcoin / U.S. Dollar
            marketInfo.category, // crypto, fx, commodities, or indices
            marketInfo.hasReferencePrice, // has reference price ?
            marketInfo.maxLeverage, // No decimals
            marketInfo.maxDeviation, // In bps, max price difference from oracle to referencePrice
            marketInfo.fee, // In bps. 10 = 0.1%
            marketInfo.liqThreshold, // In bps
            marketInfo.fundingFactor, // Yearly funding rate if OI is completely skewed to one side. In bps.
            marketInfo.minOrderAge, // Min order age before is can be executed. In seconds
            marketInfo.priceMaxAge, // Max  price age, in seconds
            marketInfo.priceFeedId, // price feed id
            marketInfo.isReduceOnly, // accepts only reduce only orders
            marketInfo.priceSpread  // market's price spread
        );
        bytes32 action = keccak256(abi.encodePacked("setMarket", _target, market,marketEncode));
        _setPendingAction(action);
        emit SignalSetMarket(_target, market, marketInfo);
    }

    function setMarket(address _target, bytes10 market, IStore.Market memory marketInfo) external onlyAdmin {
        bytes memory marketEncode = abi.encodePacked(
            marketInfo.name, // Market's full name, e.g. Bitcoin / U.S. Dollar
            marketInfo.category, // crypto, fx, commodities, or indices
            marketInfo.hasReferencePrice, //  has reference price ?
            marketInfo.maxLeverage, // No decimals
            marketInfo.maxDeviation, // In bps, max price difference from oracle to referencePrice
            marketInfo.fee, // In bps. 10 = 0.1%
            marketInfo.liqThreshold, // In bps
            marketInfo.fundingFactor, // Yearly funding rate if OI is completely skewed to one side. In bps.
            marketInfo.minOrderAge, // Min order age before is can be executed. In seconds
            marketInfo.priceMaxAge, // Max price age, in seconds
            marketInfo.priceFeedId, // price feed id
            marketInfo.isReduceOnly, // accepts only reduce only orders
            marketInfo.priceSpread // market's price spread
        );
        bytes32 action = keccak256(abi.encodePacked("setMarket", _target, market,marketEncode));
        _validateAction(action);
        _clearAction(action);
        IStore(_target).setMarket(market, marketInfo);
    }

    function setMarketWithoutSignal(address _target, bytes10 _market, IStore.Market memory _marketInfo) external onlyAdmin {
        IStore.Market memory storedMarketInfo = IStore(_target).getMarket(_market);
        storedMarketInfo.maxLeverage = _marketInfo.maxLeverage;        
        storedMarketInfo.maxDeviation = _marketInfo.maxDeviation;        
        storedMarketInfo.minOrderAge = _marketInfo.minOrderAge;
        storedMarketInfo.priceMaxAge = _marketInfo.priceMaxAge;
        storedMarketInfo.isReduceOnly = _marketInfo.isReduceOnly;
        storedMarketInfo.priceSpread = _marketInfo.priceSpread;

        IStore(_target).setMarket(_market, storedMarketInfo);
    }


    function setFeeShare(address _target, uint256 bps) external onlyAdmin {
        IStore(_target).setFeeShare(bps);
    }

    function setBufferPayoutPeriod(address _target, uint256 period) external onlyAdmin {
        IStore(_target).setBufferPayoutPeriod(period);
    }

    function setMaxLiquidityOrderTTL(address _target, uint256 _maxLiquidityOrderTTL) external onlyAdmin {
        IStore(_target).setMaxLiquidityOrderTTL(_maxLiquidityOrderTTL);
    }

    function setUtilizationMultiplier(address _target, address asset, uint256 utilizationMultiplier) external onlyAdmin {
        IStore(_target).setUtilizationMultiplier(asset, utilizationMultiplier);
    }

    function withdrawFees(address _target, address _asset) external onlyAdmin {
        IStore(_target).withdrawFees(_asset);
    }

    function setIsPublicDeposit(address _target, bool _isPublicDeposit) external onlyAdmin {
        IStore(_target).setIsPublicDeposit(_isPublicDeposit);
    }

    function setWhitelistedDepositer(address _target, address keeper, bool isActive) external onlyAdmin {
        IStore(_target).setWhitelistedDepositer(keeper, isActive);
    }

    function setPriceFeedStalePeriod(address _target, bytes20 _priceFeedOrSymbol, uint256 _stalePriod) external onlyAdmin {
        IReferencePriceFeed(_target).setPriceFeedStalePeriod(_priceFeedOrSymbol, _stalePriod);
    }

    function cancelAction(bytes32 _action) external onlyAdmin {
        _clearAction(_action);
    }

    function _setPendingAction(bytes32 _action) private {
        require(pendingActions[_action] == 0, "TL: action already signalled");
        pendingActions[_action] = block.timestamp + buffer;
        emit SignalPendingAction(_action);
    }

    function _validateAction(bytes32 _action) private view {
        uint256 pendingAction = pendingActions[_action];
        require(pendingAction != 0, "TL: action not signalled");
        require(pendingAction < block.timestamp, "TL: action time not yet passed");
        require(pendingAction + maxDuration > block.timestamp, "TL: action expired");
    }

    function _clearAction(bytes32 _action) private {
        require(pendingActions[_action] != 0, "TL: invalid _action");
        delete pendingActions[_action];
        emit ClearAction(_action);
    }
}
