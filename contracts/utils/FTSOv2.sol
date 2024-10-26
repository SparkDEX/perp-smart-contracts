// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/flare/ContractRegistry.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/flare/FtsoV2Interface.sol";
import {IFeeCalculator} from "@flarenetwork/flare-periphery-contracts/flare/IFeeCalculator.sol";
import {IFtsoFeedPublisher} from "@flarenetwork/flare-periphery-contracts/flare/IFtsoFeedPublisher.sol";

import './Governable.sol';
import './AddressStorage.sol';
import '@openzeppelin/contracts/utils/Address.sol';

// Relay contract's statedata information required for timestamp calculation by voting round id
interface IRelay {
    struct StateData {
        /// The protocol id of the random number protocol.
        uint8 randomNumberProtocolId;
        /// The timestamp of the first voting round start.
        uint32 firstVotingRoundStartTs;
        /// The duration of a voting epoch in seconds.
        uint8 votingEpochDurationSeconds;
        /// The start voting round id of the first reward epoch.
        uint32 firstRewardEpochStartVotingRoundId;
        /// The duration of a reward epoch in voting epochs.
        uint16 rewardEpochDurationInVotingEpochs;
        /// The threshold increase in BIPS for signing with old signing policy.
        uint16 thresholdIncreaseBIPS;

        // Publication of current random number
        /// The voting round id of the random number generation.
        uint32 randomVotingRoundId;
        /// If true, the random number is generated secure.
        bool isSecureRandom;

        /// The last reward epoch id for which the signing policy has been initialized.
        uint32 lastInitializedRewardEpoch;

        /// If true, signing policy relay is disabled.
        bool noSigningPolicyRelay;

        /// If reward epoch of a message is less then
        /// lastInitializedRewardEpoch - messageFinalizationWindowInRewardEpochs
        /// relaying the message is rejected.
        uint32 messageFinalizationWindowInRewardEpochs;
    }

    function stateData() external view returns(StateData memory);
}

/// @title FTSOv2
/// @notice https://dev.flare.network/ftso/getting-started
contract FTSOv2 is Governable{
    using Address for address payable;

    // -- Constants -- //
    uint256 public constant MIN_RATE_STALE_PERIOD = 60; // 1 minutes
    uint256 public constant MAX_RATE_STALE_PERIOD = 600;  // 10 minutes

    AddressStorage public immutable addressStorage;
    address public executorAddress;
    mapping(bytes21 => uint256) public priceFeedStalePeriod;  

    uint32 public immutable firstVotingRoundStartTs;
    uint8 public immutable votingEpochDurationSeconds;


    FtsoV2Interface public immutable ftsoV2;
    IFeeCalculator public immutable feeCalculator;
    IFtsoFeedPublisher public immutable ftsoFeedPublisher;

    event PriceFeedStalePeriodUpdated(bytes21 priceFeedId, uint256 stalePeriod);
    event Link(address executor);

    // -- Errors -- //
    error InvalidPrice();
    error StaleRate();

    /// @dev Initializes flare contract registry
    constructor(AddressStorage _addressStorage)  {
        addressStorage = _addressStorage;
        ftsoV2 = ContractRegistry.getFtsoV2();
        feeCalculator = ContractRegistry.getFeeCalculator();
        ftsoFeedPublisher = IFtsoFeedPublisher(ContractRegistry.getContractAddressByName("FtsoFeedPublisher"));
        IRelay.StateData memory stateData = IRelay(ContractRegistry.getContractAddressByName("Relay")).stateData();
        require(stateData.firstVotingRoundStartTs > 0,"!start-ts-gt-zero");
        require(stateData.votingEpochDurationSeconds > 0,"!epoch-sec-gt-zero");
        firstVotingRoundStartTs = stateData.firstVotingRoundStartTs;
        votingEpochDurationSeconds = stateData.votingEpochDurationSeconds;
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
        emit Link(executorAddress);
    }

    /// @notice Set FTSO price feed stale period
    /// @dev Only callable by governance
    /// @param _tokenSymbol Token symbol
    /// @param _stalePeriod Stale Period in seconds
    function setPriceFeedStalePeriod(bytes21 _tokenSymbol, uint256 _stalePeriod) external onlyGov {
        require(_stalePeriod >= MIN_RATE_STALE_PERIOD, '!min-stale-period');
        require(_stalePeriod <= MAX_RATE_STALE_PERIOD, '!max-stale-period');
        priceFeedStalePeriod[_tokenSymbol] = _stalePeriod;
        emit PriceFeedStalePeriodUpdated(_tokenSymbol, _stalePeriod);
    }

    /// @notice Returns fee value for single feed id
    function getFee(bytes21 _feedId) external view returns (uint256 ) {
        bytes21[] memory feedIds = new bytes21[](1);
        feedIds[0] = _feedId;
        return feeCalculator.calculateFeeByIds(feedIds);
    }

    /// @notice Returns fee value for multiple feed ids
    function getFees(bytes21[] calldata _feedIds) external view returns (uint256 ) {
        return feeCalculator.calculateFeeByIds(_feedIds);
    }


    /// @notice Returns the latest ftso block-latency price for using primary price
    /// @param _feedIds price feed ids in FTSOv2
    function getPrices(bytes21[] calldata _feedIds) external payable onlyExecutor returns(uint256[] memory prices, uint64 publishTime, uint256 remainingValue){
        uint256 fee = feeCalculator.calculateFeeByIds(_feedIds);
        require(msg.value >= fee, '!ftso-fee');
        (prices, publishTime) = ftsoV2.getFeedsByIdInWei{value: fee}(_feedIds);

        remainingValue = msg.value - fee;
        if (remainingValue > 0) {
            payable(msg.sender).sendValue(remainingValue);
        }  
    }

    /// @notice Returns the latest ftso scaling price for using reference price
    /// @param _feedId feed id in FTSOv2
    function getPrice(bytes21 _feedId) external view returns (uint256) {
        if (_feedId == bytes21(0)) return 0;
        IFtsoFeedPublisher.Feed memory feed = ftsoFeedPublisher.getCurrentFeed(_feedId);

        if (feed.value <= 0) {
            revert InvalidPrice();
        }

        uint256 stalePeriod = priceFeedStalePeriod[_feedId] > 0 ? priceFeedStalePeriod[_feedId] : MAX_RATE_STALE_PERIOD; 
        uint256 timestamp = getTimestampByVotingRoundId(feed.votingRoundId);

        if (timestamp < block.timestamp - stalePeriod) {
            revert StaleRate();
        }

        int256 decimalsDiff = 18 - feed.decimals;
        uint256 price = uint32(feed.value);
        // value in wei (18 decimals)
        if (decimalsDiff < 0) {
            price = price / (10 ** uint256(-decimalsDiff));
        } else {
            price = price * (10 ** uint256(decimalsDiff));
        }

        return price;
    }

    function getTimestampByVotingRoundId(uint32 _votingRoundId) public view returns (uint256) {
        return  _votingRoundId * votingEpochDurationSeconds + firstVotingRoundStartTs ;        
    }

}