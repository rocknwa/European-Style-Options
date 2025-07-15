// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title Covered European-Style Options
/// @notice A smart contract for trading Covered Calls and Cash-Secured Puts with ETH as the underlying asset and DAI for premiums/strikes.
/// @dev Supports writing, buying, exercising, and canceling options. Uses Chainlink for price feeds and OpenZeppelin for security.
contract Options is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Constants for magic numbers
    uint256 private constant ONE_ETHER = 1e18; // 10^18 for ETH decimals
    uint256 private constant ONE_DAY_IN_SECONDS = 1 days; // 1 day in seconds
    uint256 private constant PRICE_FEED_STALENESS_THRESHOLD = 1 hours; // Price feed staleness threshold

    /// @notice Chainlink price feed for DAI/ETH
    AggregatorV3Interface internal immutable daiEthPriceFeed;

    /// @notice DAI token contract
    IERC20 internal immutable dai;

    /// @notice Counter for generating unique option IDs
    uint256 s_optionCounter;

    /// @notice Mapping of option ID to Option details
    mapping(uint256 => Option) public s_optionIdToOption;

    /// @notice Mapping of trader address to their option IDs
    mapping(address => uint256[]) public s_tradersPosition;

    /// @notice States of an option
    enum OptionState {
        Open,
        Bought,
        Cancelled,
        Exercised
    }

    /// @notice Types of options (Call or Put)
    enum OptionType {
        Call,
        Put
    }

    /// @notice Struct to store option details
    struct Option {
        address writer; // Address of the option writer
        address buyer; // Address of the option buyer
        uint256 amount; // Number of options
        uint256 strike; // Strike price (DAI per ETH)
        uint256 premiumDue; // Premium paid by buyer in DAI
        uint256 expiration; // Timestamp of option expiration
        uint256 collateral; // ETH collateral provided by writer
        OptionState optionState; // Current state of the option
        OptionType optionType; // Call or Put
    }

    /// @notice Error for failed transfers
    error TransferFailed();

    /// @notice Error for zero or invalid inputs
    error NeedsMoreThanZero();

    /// @notice Error for invalid option ID
    error OptionNotValid(uint256 optionId);

    /// @notice Error for stale or invalid price feed data
    error InvalidPriceFeed();

    /// @notice Error for invalid price data
    error InvalidPrice();

    /// @notice Error for invalid price feed address
    error InvalidPriceFeedAddress();

    /// @notice Error for invalid DAI address
    error InvalidDaiAddress();

    /// @notice Error for insufficient ETH collateral for call option
    error InsufficientCallCollateral();

    /// @notice Error for strike price not matching market price for call option
    error CallStrikeNotMarketPrice();

    /// @notice Error for not being a call option
    error NotCallOption();

    /// @notice Error for insufficient ETH collateral for put option
    error InsufficientPutCollateral();

    /// @notice Error for strike price not matching market price for put option
    error PutStrikeNotMarketPrice();

    /// @notice Error for not being a put option
    error NotPutOption();

    /// @notice Error for not being the buyer
    error NotBuyer();

    /// @notice Error for option not being bought
    error NeverBought();

    /// @notice Error for option not being expired
    error NotExpired();

    /// @notice Error for call option price not greater than strike
    error CallPriceNotGreaterThanStrike();

    /// @notice Error for call option price not less than strike (used for worthless expiry)
    error CallPriceNotLessThanStrike();

    /// @notice Error for put option price not less than strike
    error PutPriceNotLessThanStrike();

    /// @notice Error for put option price not greater than strike (used for worthless expiry)
    error PutPriceNotGreaterThanStrike();

    /// @notice Error for insufficient ETH balance
    error InsufficientEthBalance();

    /// @notice Error for not being the writer
    error NotWriter();

    /// @notice Error for option not being cancelled
    error NotCancelled();

    /// @notice Emitted when a call option is opened
    event CallOptionOpen(
        uint256 indexed id,
        address indexed writer,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint256 expiration,
        uint256 collateral
    );

    /// @notice Emitted when a put option is opened
    event PutOptionOpen(
        uint256 indexed id,
        address indexed writer,
        uint256 amount,
        uint256 strike,
        uint256 premium,
        uint256 expiration,
        uint256 collateral
    );

    /// @notice Emitted when a call option is bought
    event CallOptionBought(address indexed buyer, uint256 indexed id);

    /// @notice Emitted when a put option is bought
    event PutOptionBought(address indexed buyer, uint256 indexed id);

    /// @notice Emitted when a call option is exercised
    event CallOptionExercised(address indexed buyer, uint256 indexed id);

    /// @notice Emitted when a put option is exercised
    event PutOptionExercised(address indexed buyer, uint256 indexed id);

    /// @notice Emitted when an option expires worthless
    event OptionExpiresWorthless(address indexed writer, uint256 indexed id);

    /// @notice Emitted when a writer retrieves collateral from an expired option
    event FundsRetrieved(address indexed writer, uint256 indexed id, uint256 collateral);

    /// @notice Constructor to initialize price feed and DAI token addresses
    /// @param _priceFeed Address of the Chainlink DAI/ETH price feed
    /// @param _daiAddr Address of the DAI ERC20 token
    constructor(address _priceFeed, address _daiAddr) Ownable(msg.sender) {
        if (_priceFeed == address(0)) revert InvalidPriceFeedAddress();
        if (_daiAddr == address(0)) revert InvalidDaiAddress();
        daiEthPriceFeed = AggregatorV3Interface(_priceFeed);
        dai = IERC20(_daiAddr);
    }

    /// @notice Write a call option, locking ETH as collateral
    /// @param _amount Number of options to write
    /// @param _strike Strike price (DAI per ETH, typically set to current market price)
    /// @param _premiumDue Premium paid by buyer in DAI
    /// @param _daysToExpiry Days until option expiration
    function writeCallOption(uint256 _amount, uint256 _strike, uint256 _premiumDue, uint256 _daysToExpiry)
        external
        payable
        whenNotPaused
        moreThanZero(_amount, _strike, _premiumDue)
    {
        uint256 marketPriceDaiPerEth = getPriceFeed(ONE_ETHER); // Get DAI per 1 ETH (normalized to 18 decimals)
        uint256 requiredCollateral = (_amount * ONE_ETHER) / marketPriceDaiPerEth; // ETH collateral needed

        if (msg.value != requiredCollateral) revert InsufficientCallCollateral();
        if (marketPriceDaiPerEth != _strike) revert CallStrikeNotMarketPrice();

        uint256 optionId = s_optionCounter++;
        s_optionIdToOption[optionId] = Option({
            writer: payable(msg.sender),
            buyer: address(0),
            amount: _amount,
            strike: _strike,
            premiumDue: _premiumDue,
            expiration: block.timestamp + (_daysToExpiry * ONE_DAY_IN_SECONDS),
            collateral: msg.value,
            optionState: OptionState.Open,
            optionType: OptionType.Call
        });

        s_tradersPosition[msg.sender].push(optionId);
        emit CallOptionOpen(
            optionId,
            msg.sender,
            _amount,
            _strike,
            _premiumDue,
            block.timestamp + (_daysToExpiry * ONE_DAY_IN_SECONDS),
            msg.value
        );
    }

    /// @notice Buy an open call option by paying the premium in DAI
    /// @param _optionId ID of the option to buy
    function buyCallOption(uint256 _optionId)
        external
        nonReentrant
        whenNotPaused
        optionExists(_optionId)
        isValidOpenOption(_optionId)
    {
        Option storage option = s_optionIdToOption[_optionId];

        if (option.optionType != OptionType.Call) revert NotCallOption();
        option.buyer = msg.sender;
        option.optionState = OptionState.Bought;
        s_tradersPosition[msg.sender].push(_optionId);
        emit CallOptionBought(msg.sender, _optionId);
        dai.safeTransferFrom(msg.sender, option.writer, option.premiumDue);
    }

    /// @notice Write a put option, locking ETH as collateral
    /// @param _amount Number of options to write
    /// @param _strike Strike price (DAI per ETH, typically set to current market price)
    /// @param _premiumDue Premium paid by buyer in DAI
    /// @param _daysToExpiry Days until option expiration
    function writePutOption(uint256 _amount, uint256 _strike, uint256 _premiumDue, uint256 _daysToExpiry)
        external
        payable
        whenNotPaused
        moreThanZero(_amount, _strike, _premiumDue)
    {
        uint256 marketPriceDaiPerEth = getPriceFeed(ONE_ETHER); // Get DAI per 1 ETH
        uint256 requiredCollateral = (_amount * ONE_ETHER) / marketPriceDaiPerEth; // ETH collateral needed

        if (msg.value != requiredCollateral) revert InsufficientPutCollateral();
        if (marketPriceDaiPerEth != _strike) revert PutStrikeNotMarketPrice();

        uint256 optionId = s_optionCounter++;
        s_optionIdToOption[optionId] = Option({
            writer: payable(msg.sender),
            buyer: address(0),
            amount: _amount,
            strike: _strike,
            premiumDue: _premiumDue,
            expiration: block.timestamp + (_daysToExpiry * ONE_DAY_IN_SECONDS),
            collateral: msg.value,
            optionState: OptionState.Open,
            optionType: OptionType.Put
        });

        s_tradersPosition[msg.sender].push(optionId);
        emit PutOptionOpen(
            optionId,
            msg.sender,
            _amount,
            _strike,
            _premiumDue,
            block.timestamp + (_daysToExpiry * ONE_DAY_IN_SECONDS),
            msg.value
        );
    }

    /// @notice Buy an open put option by paying the premium in DAI
    /// @param _optionId ID of the option to buy
    function buyPutOption(uint256 _optionId)
        external
        nonReentrant
        whenNotPaused
        optionExists(_optionId)
        isValidOpenOption(_optionId)
    {
        Option storage option = s_optionIdToOption[_optionId];
        if (option.optionType != OptionType.Put) revert NotPutOption();

        option.buyer = msg.sender;
        option.optionState = OptionState.Bought;
        s_tradersPosition[msg.sender].push(_optionId);

        emit PutOptionBought(msg.sender, _optionId);
        dai.safeTransferFrom(msg.sender, option.writer, option.premiumDue);
    }

    /// @notice Exercise a call option at expiration
    /// @param _optionId ID of the option to exercise
    function exerciseCallOption(uint256 _optionId)
        external
        payable
        nonReentrant
        whenNotPaused
        optionExists(_optionId)
    {
        Option storage option = s_optionIdToOption[_optionId];
        if (msg.sender != option.buyer) revert NotBuyer();
        if (option.optionState != OptionState.Bought) revert NeverBought();
        if (option.expiration >= block.timestamp) revert NotExpired();
        if (option.optionType != OptionType.Call) revert NotCallOption();

        uint256 marketPriceDaiPerEth = getPriceFeed(ONE_ETHER);
        if (marketPriceDaiPerEth <= option.strike) revert CallPriceNotGreaterThanStrike();

        option.optionState = OptionState.Exercised;

        if (address(this).balance < option.collateral) revert InsufficientEthBalance();

        emit CallOptionExercised(msg.sender, _optionId);
        (bool success,) = payable(msg.sender).call{value: option.collateral}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Exercise a put option at expiration
    /// @param _optionId ID of the option to exercise
    function exercisePutOption(uint256 _optionId) external payable nonReentrant whenNotPaused optionExists(_optionId) {
        Option storage option = s_optionIdToOption[_optionId];
        if (msg.sender != option.buyer) revert NotBuyer();
        if (option.optionState != OptionState.Bought) revert NeverBought();
        if (option.expiration >= block.timestamp) revert NotExpired();
        if (option.optionType != OptionType.Put) revert NotPutOption();

        uint256 marketPriceDaiPerEth = getPriceFeed(ONE_ETHER);
        if (marketPriceDaiPerEth >= option.strike) revert PutPriceNotLessThanStrike();

        option.optionState = OptionState.Exercised;

        if (address(this).balance < option.collateral) revert InsufficientEthBalance();
        emit PutOptionExercised(msg.sender, _optionId);
        (bool success,) = payable(msg.sender).call{value: option.collateral}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Cancel an expired, worthless option
    /// @param _optionId ID of the option to cancel
    function optionExpiresWorthless(uint256 _optionId) external whenNotPaused optionExists(_optionId) {
        Option storage option = s_optionIdToOption[_optionId];
        if (msg.sender != option.writer) revert NotWriter();
        if (option.optionState != OptionState.Bought) revert NeverBought();
        if (option.expiration >= block.timestamp) revert NotExpired();

        uint256 marketPriceDaiPerEth = getPriceFeed(ONE_ETHER);
        if (option.optionType == OptionType.Call) {
            if (marketPriceDaiPerEth >= option.strike) revert CallPriceNotLessThanStrike();
        } else {
            if (marketPriceDaiPerEth <= option.strike) revert PutPriceNotGreaterThanStrike();
        }

        option.optionState = OptionState.Cancelled;
        emit OptionExpiresWorthless(msg.sender, _optionId);
    }

    /// @notice Retrieve ETH collateral from a cancelled option
    /// @param _optionId ID of the cancelled option
    function retrieveExpiredFunds(uint256 _optionId) external nonReentrant whenNotPaused optionExists(_optionId) {
        Option storage option = s_optionIdToOption[_optionId];
        if (msg.sender != option.writer) revert NotWriter();

        if (option.optionState != OptionState.Cancelled) revert NotCancelled();
        if (option.expiration >= block.timestamp) revert NotExpired();

        if (address(this).balance < option.collateral) revert InsufficientEthBalance();
        emit FundsRetrieved(msg.sender, _optionId, option.collateral);
        (bool success,) = payable(msg.sender).call{value: option.collateral}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Get the current DAI/ETH price from Chainlink
    /// @param _amountInDai Amount of DAI (in 18 decimals) to convert to ETH
    /// @return Amount of ETH (in 18 decimals) for the given DAI amount
    function getPriceFeed(uint256 _amountInDai) public view returns (uint256) {
        (, int256 price,, uint256 updatedAt,) = daiEthPriceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        if (updatedAt < block.timestamp - PRICE_FEED_STALENESS_THRESHOLD) revert InvalidPriceFeed();
        uint8 decimals = daiEthPriceFeed.decimals();
        return (uint256(price) * _amountInDai) / (10 ** decimals);
    }

    /// @notice Get details of an option
    /// @param _optionId ID of the option
    /// @return Option struct containing all details
    function getOptionDetails(uint256 _optionId) external view returns (Option memory) {
        if (s_optionIdToOption[_optionId].writer == address(0)) {
            revert OptionNotValid(_optionId);
        }
        return s_optionIdToOption[_optionId];
    }

    /// @notice Get all option IDs for a trader
    /// @param _trader Address of the trader
    /// @return Array of option IDs
    function getTraderPositions(address _trader) external view returns (uint256[] memory) {
        return s_tradersPosition[_trader];
    }

    /// @notice Pause the contract (only owner)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract (only owner)
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Modifier to ensure inputs are greater than zero
    modifier moreThanZero(uint256 amount, uint256 strikePrice, uint256 premiumCost) {
        if (amount == 0 || strikePrice == 0 || premiumCost == 0) {
            revert NeedsMoreThanZero();
        }
        _;
    }

    /// @notice Modifier to ensure option exists
    modifier optionExists(uint256 optionId) {
        if (s_optionIdToOption[optionId].writer == address(0)) {
            revert OptionNotValid(optionId);
        }
        _;
    }

    /// @notice Modifier to ensure option is open and not expired
    modifier isValidOpenOption(uint256 optionId) {
        if (
            s_optionIdToOption[optionId].optionState != OptionState.Open
                || s_optionIdToOption[optionId].expiration <= block.timestamp
        ) revert OptionNotValid(optionId);
        _;
    }
}
