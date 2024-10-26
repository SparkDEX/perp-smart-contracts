// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;


import './utils/AddressStorage.sol';
import "./utils/Governable.sol";
import "./interfaces/IReferralStorage.sol";

/**
 * @title  ReferralStorage
 * @notice Implementation of referral system
 */
contract ReferralStorage is Governable, IReferralStorage {
    struct Tier {
        uint256 totalRebate; // e.g. 2400 for 24%
        uint256 discountShare; // 5000 for 50%/50%, 7000 for 30% rebates/70% discount
    }

    uint256 public constant BASIS_POINTS = 10000;

    mapping (address => uint256) public override referrerDiscountShares; // to override default value in tier
    mapping (address => uint256) public override referrerTiers; // link between user <> tier
    mapping (uint256 => Tier) public tiers;

    mapping (bytes32 => address) public override codeOwners;
    mapping (address => bytes32) public override traderReferralCodes;


    event SetTraderReferralCode(address indexed account, bytes32 code);
    event SetTier(uint256 indexed tierId, uint256 totalRebate, uint256 discountShare);
    event SetReferrerTier(address indexed referrer, uint256 tierId);
    event SetReferrerDiscountShare(address indexed referrer, uint256 discountShare);
    event RegisterCode(address indexed account, bytes32 code);
    event SetCodeOwner(address indexed account, address newAccount, bytes32 code);
    event GovSetCodeOwner(bytes32 code, address newAccount);
    event Link(address orderBook);

    // Contracts
    AddressStorage public immutable addressStorage;
    address public orderBookAddress;

    /// @dev Initializes AddressStorage address
    constructor(AddressStorage _addressStorage) {
        addressStorage = _addressStorage;
    }

    /// @dev Only callable by OrderBook contract
    modifier onlyOrderBook() {
        require(msg.sender == orderBookAddress, "!unauthorized");
        _;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        orderBookAddress = addressStorage.getAddress('OrderBook');
        emit Link(orderBookAddress);
    }

    /// @notice Set tier
    /// @dev Only callable by governance
    /// @param _tierId  tier id
    /// @param _totalRebate  e.g. 2400 for 24%
    /// @param _discountShare  5000 for 50%/50%, 7000 for 30% rebates/70% discount
    function setTier(uint256 _tierId, uint256 _totalRebate, uint256 _discountShare) external override onlyGov {
        require(_totalRebate <= BASIS_POINTS, "RS: invalid totalRebate");
        require(_discountShare <= BASIS_POINTS, "RS: invalid discountShare");

        Tier memory tier = tiers[_tierId];
        tier.totalRebate = _totalRebate;
        tier.discountShare = _discountShare;
        tiers[_tierId] = tier;
        emit SetTier(_tierId, _totalRebate, _discountShare);
    }

    /// @notice Set Referrer tier
    /// @dev Only callable by governance
    /// @param _referrer  address of referrer
    /// @param _tierId  tier id
    function setReferrerTier(address _referrer, uint256 _tierId) external override onlyGov {
        referrerTiers[_referrer] = _tierId;
        emit SetReferrerTier(_referrer, _tierId);
    }

    /// @notice Set Referrer discount share
    /// @param _discountShare  discount share
    function setReferrerDiscountShare(uint256 _discountShare) external {
        require(_discountShare <= BASIS_POINTS, "RS: invalid discountShare");

        referrerDiscountShares[msg.sender] = _discountShare;
        emit SetReferrerDiscountShare(msg.sender, _discountShare);
    }

    /// @notice Set trader referral code
    /// @dev Only callable by OrderBook contract
    /// @param _account  address of account
    /// @param _code bytes32 equivalent of code
    function setTraderReferralCode(address _account, bytes32 _code) external override onlyOrderBook {
        _setTraderReferralCode(_account, _code);
    }

    /// @notice Set trader referral code by user
    /// @param _code bytes32 equivalent of code
    function setTraderReferralCodeByUser(bytes32 _code) external {
        _setTraderReferralCode(msg.sender, _code);
    }

    /// @notice register code
    /// @param _code bytes32 equivalent of code
    function registerCode(bytes32 _code) external {
        require(_code != bytes32(0), "RS: invalid _code");
        require(codeOwners[_code] == address(0), "RS: code already exists");

        codeOwners[_code] = msg.sender;
        emit RegisterCode(msg.sender, _code);
    }

    /// @notice set code owner
    /// @param _code bytes32 equivalent of code
    /// @param _newAccount  address of new code owner
    function setCodeOwner(bytes32 _code, address _newAccount) external {
        require(_code != bytes32(0), "RS: invalid _code");
        require(_newAccount != address(0), "RS: zero address");

        address account = codeOwners[_code];
        require(msg.sender == account, "RS: forbidden");

        codeOwners[_code] = _newAccount;
        emit SetCodeOwner(msg.sender, _newAccount, _code);
    }

    /// @notice set code owner
    /// @dev Only callable by governance
    /// @param _code bytes32 equivalent of code
    /// @param _newAccount  address of new code owner
    function govSetCodeOwner(bytes32 _code, address _newAccount) external override onlyGov {
        require(_code != bytes32(0), "RS: invalid _code");
        require(_newAccount != address(0), "RS: zero address");

        codeOwners[_code] = _newAccount;
        emit GovSetCodeOwner(_code, _newAccount);
    }

    /// @notice get trader referral info
    /// @param _account address of account
    /// @return code  bytes32 equivalent of code
    /// @return referrer  address of referrer
    function getTraderReferralInfo(address _account) external override view returns (bytes32, address) {
        bytes32 code = traderReferralCodes[_account];
        address referrer;
        if (code != bytes32(0)) {
            referrer = codeOwners[code];
        }
        return (code, referrer);
    }

    /// @notice set trader referral code
    /// @dev internal function
    /// @param _account address of account
    /// @param _code  bytes32 equivalent of code
    function _setTraderReferralCode(address _account, bytes32 _code) private {
        traderReferralCodes[_account] = _code;
        emit SetTraderReferralCode(_account, _code);
    }
}
