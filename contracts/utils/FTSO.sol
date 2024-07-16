// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import "@flarenetwork/flare-periphery-contracts/flare/util-contracts/userInterfaces/IFlareContractRegistry.sol";
import "@flarenetwork/flare-periphery-contracts/flare/ftso/userInterfaces/IFtsoRegistry.sol";
import './Governable.sol';

/// @title FTSO
/// @notice https://docs.flare.network/dev/tutorials/ftso/getting-data-feeds/
contract FTSO is Governable{
    // -- Constants -- //
    address private constant FLARE_CONTRACT_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant MIN_RATE_STALE_PERIOD = 60; // 1 minutes
    uint256 public constant MAX_RATE_STALE_PERIOD = 600;  // 10 minutes

    mapping(bytes20 => uint256) public priceFeedStalePeriod;  

    IFlareContractRegistry public immutable contractRegistry;
    IFtsoRegistry public ftsoRegistry;

    event Link(address ftsoRegistry);
    event PriceFeedStalePeriodUpdated(bytes20 tokenSymbol, uint256 stalePeriod);

    // -- Errors -- //
    error InvalidPrice();
    error StaleRate();

    /// @dev Initializes flare contract registry
    constructor()  {
        contractRegistry = IFlareContractRegistry(FLARE_CONTRACT_REGISTRY);
    }

    /// @notice Initializes ftsoregistry contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        ftsoRegistry = IFtsoRegistry(contractRegistry.getContractAddressByName('FtsoRegistry'));
        emit Link(address(ftsoRegistry));
    }    

    /// @notice Set FTSO price feed stale period
    /// @dev Only callable by governance
    /// @param _tokenSymbol Token symbol
    /// @param _stalePeriod Stale Period in seconds
    function setPriceFeedStalePeriod(bytes20 _tokenSymbol, uint256 _stalePeriod) external onlyGov {
        require(_stalePeriod >= MIN_RATE_STALE_PERIOD, '!min-stale-period');
        require(_stalePeriod <= MAX_RATE_STALE_PERIOD, '!max-stale-period');
        priceFeedStalePeriod[_tokenSymbol] = _stalePeriod;
        emit PriceFeedStalePeriodUpdated(_tokenSymbol, _stalePeriod);
    }


    /// @notice Returns the latest ftso price
    /// @param _tokenSymbol Token symbol in FTSO
    function getPrice(bytes20 _tokenSymbol) public view returns (uint256) {
        if (_tokenSymbol == bytes20(0)) return 0;
        uint256 end;
        for (uint256 i; i < 20; i++) 
            if ( _tokenSymbol[i] == 0x00){
                end = i;
                break;
            }

        bytes memory _outArr = new bytes(end);
        for (uint256 i; i < end; i++) {
            _outArr[i] = _tokenSymbol[i];
        }

        (uint256 price, uint256 timestamp, uint256 decimals) = ftsoRegistry.getCurrentPriceWithDecimals(string(_outArr)); // if input value is address or not string then revert

        if (price <= 0) {
            revert InvalidPrice();
        }
        uint256 stalePeriod = priceFeedStalePeriod[_tokenSymbol] > 0 ? priceFeedStalePeriod[_tokenSymbol] : MAX_RATE_STALE_PERIOD; 

        if (timestamp < block.timestamp - stalePeriod) {
            revert StaleRate();
        }

        return (price * UNIT) / 10 ** decimals;
    }
    
}


