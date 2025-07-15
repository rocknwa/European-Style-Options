// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import "../src/Options.sol";
import {TestFun} from "./TestFun.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract OptionsTest is Test {
    Options public optionsContract;
    IERC20 public dai;
    AggregatorV3Interface public priceFeed;

    address public writer = address(0x1);
    address public buyer = address(0x2);
    address public owner = address(0x3);
    address public nonOwner = address(0x4);

    uint256 public constant INITIAL_DAI_BALANCE = 10000 * 1e18;
    uint256 public constant INITIAL_ETH_BALANCE = 10 ether;

    address public constant DAI_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant DAI_ETH_PRICE_FEED = 0x773616E4d11A78F511299002da57A0a94577F1f4;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        optionsContract = new Options(DAI_ETH_PRICE_FEED, DAI_ADDRESS);
        dai = IERC20(DAI_ADDRESS);
        priceFeed = AggregatorV3Interface(DAI_ETH_PRICE_FEED);

        // Mock Chainlink price feed to return fresh data
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                0, // roundId
                int256(373078345309925), // Example price: ~373 DAI/ETH (scaled to 8 decimals)
                0, // startedAt
                block.timestamp, // updatedAt (current block timestamp to avoid staleness)
                0 // answeredInRound
            )
        );

        vm.deal(writer, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        deal(DAI_ADDRESS, writer, INITIAL_DAI_BALANCE);
        deal(DAI_ADDRESS, buyer, INITIAL_DAI_BALANCE);

        vm.prank(buyer);
        dai.approve(address(optionsContract), type(uint256).max);

        vm.prank(writer);
        dai.approve(address(optionsContract), type(uint256).max);

        // Transfer ownership to the owner address
        optionsContract.transferOwnership(owner);
        vm.stopPrank();
    }

    // Test writing a call option
    function testWriteCallOption() public {
        uint256 amount = 1e15; // 0.001 ETH
        uint256 premiumDue = 1e17; // 0.1 DAI, scaled down proportionally
        uint256 daysToExpiry = 7;

        // Get current market price from the price feed
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        // Ensure the writer has enough ETH
        vm.deal(writer, requiredCollateral);

        // Write call option
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        // Verify option details
        Options.Option memory option = optionsContract.getOptionDetails(0);
        assertEq(option.writer, writer);
        assertEq(option.amount, amount);
        assertEq(option.strike, marketPrice);
        assertEq(option.premiumDue, premiumDue);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Open));
        assertEq(uint256(option.optionType), uint256(Options.OptionType.Call));
    }

    // Test buying a call option
    function testBuyCallOption() public {
        testWriteCallOption();

        // Buy the call option
        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        // Verify option details
        Options.Option memory option = optionsContract.getOptionDetails(0);
        assertEq(option.buyer, buyer);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Bought));
    }

    // Test exercising a call option
    function testExerciseCallOption() public {
        testBuyCallOption();

        // Fast forward time to after expiration
        vm.warp(block.timestamp + 8 days);

        // Mock price feed to simulate market price > strike
        Options.Option memory option = optionsContract.getOptionDetails(0);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(option.strike + 100 * 1e8), 0, block.timestamp, 0)
        );

        // Exercise the call option
        vm.prank(buyer);
        optionsContract.exerciseCallOption(0);

        // Verify option state
        option = optionsContract.getOptionDetails(0);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Exercised));
    }

    // Test writing a put option
    function testWritePutOption() public {
        uint256 amount = 1e15; // Reduced from 1e18 to 0.001 units
        uint256 premiumDue = 1e17; // Adjusted from 1e20 to a reasonable premium (0.1 ETH)
        uint256 daysToExpiry = 7;

        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice; // Approx. 2.68 ETH

        vm.deal(writer, requiredCollateral); // Ensure writer has just enough ETH

        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        // Verify option details
        Options.Option memory option = optionsContract.getOptionDetails(0);
        assertEq(option.writer, writer);
        assertEq(option.amount, amount);
        assertEq(option.strike, marketPrice);
        assertEq(option.premiumDue, premiumDue);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Open));
        assertEq(uint256(option.optionType), uint256(Options.OptionType.Put));
    }

    // Test buying a put option
    function testBuyPutOption() public {
        testWritePutOption();

        // Buy the put option
        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        // Verify option details
        Options.Option memory option = optionsContract.getOptionDetails(0);
        assertEq(option.buyer, buyer);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Bought));
    }

    // Test exercising a put option
    function testExercisePutOption() public {
        testBuyPutOption();

        // Fast forward time to after expiration
        vm.warp(block.timestamp + 8 days);

        // Mock price feed to simulate market price < strike
        Options.Option memory option = optionsContract.getOptionDetails(0);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(option.strike - 100 * 1e8), 0, block.timestamp, 0)
        );

        // Exercise the put option
        vm.prank(buyer);
        optionsContract.exercisePutOption(0);

        // Verify option state
        option = optionsContract.getOptionDetails(0);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Exercised));
    }

    // Test option expiring worthless
    function testOptionExpiresWorthless() public {
        testBuyCallOption();

        // Fast forward time to after expiration
        vm.warp(block.timestamp + 8 days);

        // Mock price feed to simulate market price < strike for call
        Options.Option memory option = optionsContract.getOptionDetails(0);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(option.strike - 100 * 1e8), 0, block.timestamp, 0)
        );

        // Cancel the worthless option
        vm.prank(writer);
        optionsContract.optionExpiresWorthless(0);

        // Verify option state
        option = optionsContract.getOptionDetails(0);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Cancelled));
    }

    // Test retrieving expired funds
    function testRetrieveExpiredFunds() public {
        // Existing setup: write option, buy it, let it expire worthless...
        testOptionExpiresWorthless();

        vm.prank(writer);
        optionsContract.retrieveExpiredFunds(0);

        Options.Option memory option = optionsContract.getOptionDetails(0);
        assertEq(writer.balance, option.collateral); // Check against actual collateral
    }

    // Test edge case: Buy an already bought option
    function test_RevertBuyAlreadyBoughtOption() public {
        // Existing setup: write and buy the option once...
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (1e15 * 1e18) / marketPrice;
        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(1e15, marketPrice, 1e17, 7);
        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        // Attempt to buy again and expect revert
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Options.OptionNotValid.selector, 0));
        optionsContract.buyCallOption(0);
    }

    // Test moreThanZero modifier: zero amount
    function test_RevertWriteCallOptionZeroAmount() public {
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        vm.prank(writer);
        vm.expectRevert(Options.NeedsMoreThanZero.selector);
        optionsContract.writeCallOption{value: 0}(0, marketPrice, 1e17, 7);
    }

    // Test moreThanZero modifier: zero strike
    function test_RevertWriteCallOptionZeroStrike() public {
        uint256 requiredCollateral = 1e15; // Arbitrary small amount
        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert(Options.NeedsMoreThanZero.selector);
        optionsContract.writeCallOption{value: requiredCollateral}(1e15, 0, 1e17, 7);
    }

    // Test moreThanZero modifier: zero premium
    function test_RevertWriteCallOptionZeroPremium() public {
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (1e15 * 1e18) / marketPrice;
        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert(Options.NeedsMoreThanZero.selector);
        optionsContract.writeCallOption{value: requiredCollateral}(1e15, marketPrice, 0, 7);
    }

    // Test optionExists modifier: invalid option ID
    function test_RevertBuyCallOptionInvalidId() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Options.OptionNotValid.selector, 999));
        optionsContract.buyCallOption(999);
    }

    // Test isValidOpenOption modifier: expired option
    function test_RevertBuyCallOptionExpired() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.warp(block.timestamp + 8 days); // Expire option
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Options.OptionNotValid.selector, 0));
        optionsContract.buyCallOption(0);
    }

    // Test invalid price feed: negative price
    function test_RevertWriteCallOptionNegativePrice() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, -373078345309925, 0, block.timestamp, 0)
        );

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert(Options.InvalidPrice.selector);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);
    }

    // Test invalid price feed: stale data
    function test_RevertWriteCallOptionStalePrice() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, 373078345309925, 0, block.timestamp - 2 hours, 0)
        );

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert(Options.InvalidPriceFeed.selector);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);
    }

    // Test insufficient collateral
    function test_RevertWriteCallOptionInsufficientCollateral() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral / 2); // Provide less than required
        vm.prank(writer);
        vm.expectRevert(Options.InsufficientCallCollateral.selector);
        optionsContract.writeCallOption{value: requiredCollateral / 2}(amount, marketPrice, premiumDue, daysToExpiry);
    }

    // Test incorrect strike price
    function test_RevertWriteCallOptionInvalidStrike() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert(Options.CallStrikeNotMarketPrice.selector);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice + 1, premiumDue, daysToExpiry);
    }

    // Test non-buyer attempting to exercise call option
    function test_RevertExerciseCallOptionNonBuyer() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(nonOwner); // Non-buyer
        vm.expectRevert(Options.NotBuyer.selector);
        optionsContract.exerciseCallOption(0);
    }

    // Test exercising call option before expiration
    function test_RevertExerciseCallOptionNotExpired() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.NotExpired.selector);
        optionsContract.exerciseCallOption(0);
    }

    // Test exercising call option out of the money
    function test_RevertExerciseCallOptionOutOfMoney() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.CallPriceNotGreaterThanStrike.selector);
        optionsContract.exerciseCallOption(0);
    }

    // Test pause functionality
    function testPause() public {
        vm.prank(owner);
        optionsContract.pause();

        assertTrue(optionsContract.paused());
    }

    // Test unpause functionality
    function testUnpause() public {
        vm.prank(owner);
        optionsContract.pause();
        vm.prank(owner);
        optionsContract.unpause();

        assertFalse(optionsContract.paused());
    }

    // Test non-owner attempting to pause
    function test_RevertPauseNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        optionsContract.pause();
    }

    // Test non-owner attempting to unpause
    function test_RevertUnpauseNonOwner() public {
        vm.prank(owner);
        optionsContract.pause();

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        optionsContract.unpause();
    }

    // Test writing option when paused
    function test_RevertWriteCallOptionWhenPaused() public {
        vm.prank(owner);
        optionsContract.pause();

        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert("EnforcedPause()");
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);
    }

    // Test getTraderPositions
    function testGetTraderPositions() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        uint256[] memory positions = optionsContract.getTraderPositions(writer);
        assertEq(positions.length, 2);
        assertEq(positions[0], 0);
        assertEq(positions[1], 1);
    }

    // Test transfer failure during exercise (mock low contract balance and failed transfer)
    // Test transfer failure during exercise (mock low contract balance and failed transfer)
    function test_RevertExerciseCallOptionTransferFailed() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        // Fund writer with required collateral
        vm.deal(writer, requiredCollateral);

        // Write a call option
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        // Deploy a contract to act as the buyer (with no receive function)
        TestFun testFun = new TestFun();

        // Fund testFun with enough DAI to cover both premium and strike price
        deal(DAI_ADDRESS, address(testFun), premiumDue + marketPrice);

        // Approve DAI transfer for testFun (for both premium and strike price)
        vm.prank(address(testFun));
        dai.approve(address(optionsContract), premiumDue + marketPrice);

        // Buy the call option with testFun
        vm.prank(address(testFun));
        optionsContract.buyCallOption(0);

        // Fast forward to after expiration
        vm.warp(block.timestamp + 8 days);

        // Mock price feed to simulate market price > strike
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        // Test 1: Simulate low contract balance to trigger InsufficientEthBalance
        vm.deal(address(optionsContract), 0);
        vm.prank(address(testFun));
        vm.expectRevert(Options.InsufficientEthBalance.selector);
        optionsContract.exerciseCallOption(0);

        // Test 2: Restore contract balance and test TransferFailed due to testFun lacking a receive function
        vm.deal(address(optionsContract), requiredCollateral);

        vm.prank(address(testFun));
        vm.expectRevert(Options.TransferFailed.selector);
        optionsContract.exerciseCallOption(0);
    }

    // Test constructor with zero price feed address
    function test_RevertConstructorZeroPriceFeed() public {
        vm.expectRevert(Options.InvalidPriceFeedAddress.selector);
        new Options(address(0), DAI_ADDRESS);
    }

    // Test constructor with zero DAI address
    function test_RevertConstructorZeroDaiAddress() public {
        vm.expectRevert(Options.InvalidDaiAddress.selector);
        new Options(DAI_ETH_PRICE_FEED, address(0));
    }

    // Test exercising call option that was never bought
    function test_RevertExerciseCallOptionNotBought() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.NotBuyer.selector);
        optionsContract.exerciseCallOption(0);
    }

    // Test exercising call option with a put option
    function test_RevertExerciseCallOptionWithPut() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.NotCallOption.selector);
        optionsContract.exerciseCallOption(0);
    }

    // Test exercising put option that was never bought
    function test_RevertExercisePutOptionNotBought() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.NotBuyer.selector);
        optionsContract.exercisePutOption(0);
    }

    // Test exercising put option with a call option
    function test_RevertExercisePutOptionWithCall() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.NotPutOption.selector);
        optionsContract.exercisePutOption(0);
    }

    // Test non-writer attempting to expire worthless option
    function test_RevertOptionExpiresWorthlessNonWriter() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer); // Non-writer
        vm.expectRevert(Options.NotWriter.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test expiring worthless option that was never bought
    function test_RevertOptionExpiresWorthlessNotBought() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        vm.expectRevert(Options.NeverBought.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test expiring worthless option before expiration
    function test_RevertOptionExpiresWorthlessNotExpired() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        // Not expired
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        vm.expectRevert(Options.NotExpired.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test expiring worthless put option
    function testOptionExpiresWorthlessPut() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        optionsContract.optionExpiresWorthless(0);

        Options.Option memory option = optionsContract.getOptionDetails(0);
        assertEq(uint256(option.optionState), uint256(Options.OptionState.Cancelled));
    }

    // Test expiring worthless call option in the money
    function test_RevertOptionExpiresWorthlessCallInTheMoney() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        vm.expectRevert(Options.CallPriceNotLessThanStrike.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test expiring worthless put option in the money
    function test_RevertOptionExpiresWorthlessPutInTheMoney() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        vm.expectRevert(Options.PutPriceNotGreaterThanStrike.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test retrieving funds from non-cancelled option
    function test_RevertRetrieveExpiredFundsNotCancelled() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.prank(writer);
        vm.expectRevert(Options.NotCancelled.selector);
        optionsContract.retrieveExpiredFunds(0);
    }

    // Test retrieving funds before expiration
    function test_RevertRetrieveExpiredFundsNotExpired() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        optionsContract.optionExpiresWorthless(0);

        vm.warp(block.timestamp - 1 days); // Rewind to before expiration
        vm.prank(writer);
        vm.expectRevert(Options.NotExpired.selector);
        optionsContract.retrieveExpiredFunds(0);
    }

    // Test non-writer attempting to retrieve expired funds
    function test_RevertRetrieveExpiredFundsNonWriter() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        optionsContract.optionExpiresWorthless(0);

        vm.prank(buyer);
        vm.expectRevert(Options.NotWriter.selector);
        optionsContract.retrieveExpiredFunds(0);
    }

    // Test transfer failure when retrieving expired funds
    function test_RevertRetrieveExpiredFundsCallFailure() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        // Deploy a contract to act as the writer (with no receive function)
        TestFun testFun = new TestFun();

        // Fund the contract with required collateral
        vm.deal(address(testFun), requiredCollateral);

        // Write a call option from the contract address
        vm.prank(address(testFun));
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        // Buyer purchases the call option
        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        // Fast forward time to after expiration
        vm.warp(block.timestamp + 8 days);

        // Mock price feed to simulate market price < strike (option expires worthless)
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        // Writer cancels the worthless option
        vm.prank(address(testFun));
        optionsContract.optionExpiresWorthless(0);

        // Attempt to retrieve expired funds, expecting transfer to fail (no receive function)
        vm.prank(address(testFun));
        vm.expectRevert(Options.TransferFailed.selector);
        optionsContract.retrieveExpiredFunds(0);
    }

    // Test exercising put option out of the money
    function test_RevertExercisePutOptionOutOfMoney() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice + 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(buyer);
        vm.expectRevert(Options.PutPriceNotLessThanStrike.selector);
        optionsContract.exercisePutOption(0);
    }

    // Test exercising put option with non-buyer (bought option)
    function test_RevertExercisePutOptionNonBuyer() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(nonOwner); // Non-buyer
        vm.expectRevert(Options.NotBuyer.selector);
        optionsContract.exercisePutOption(0);
    }

    // Test optionExpiresWorthless with market price equal to strike for call
    function test_RevertOptionExpiresWorthlessCallPriceEqualStrike() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        vm.expectRevert(Options.CallPriceNotLessThanStrike.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test optionExpiresWorthless with market price equal to strike for put
    function test_RevertOptionExpiresWorthlessPutPriceEqualStrike() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyPutOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        vm.expectRevert(Options.PutPriceNotGreaterThanStrike.selector);
        optionsContract.optionExpiresWorthless(0);
    }

    // Test insufficient ETH balance in retrieveExpiredFunds
    function test_RevertRetrieveExpiredFundsInsufficientEthBalance() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        optionsContract.writeCallOption{value: requiredCollateral}(amount, marketPrice, premiumDue, daysToExpiry);

        vm.prank(buyer);
        optionsContract.buyCallOption(0);

        vm.warp(block.timestamp + 8 days);
        vm.mockCall(
            DAI_ETH_PRICE_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(marketPrice - 100 * 1e8), 0, block.timestamp, 0)
        );

        vm.prank(writer);
        optionsContract.optionExpiresWorthless(0);

        // Clear contract's ETH balance
        vm.deal(address(optionsContract), 0);

        vm.prank(writer);
        vm.expectRevert(Options.InsufficientEthBalance.selector);
        optionsContract.retrieveExpiredFunds(0);
    }

    // Test writePutOption with insufficient collateral
    function test_RevertWritePutOptionInsufficientCollateral() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral / 2); // Provide less than required
        vm.prank(writer);
        vm.expectRevert(Options.InsufficientPutCollateral.selector);
        optionsContract.writePutOption{value: requiredCollateral / 2}(amount, marketPrice, premiumDue, daysToExpiry);
    }

    // Test writePutOption with invalid strike price
    function test_RevertWritePutOptionInvalidStrike() public {
        uint256 amount = 1e15;
        uint256 premiumDue = 1e17;
        uint256 daysToExpiry = 7;
        uint256 marketPrice = optionsContract.getPriceFeed(1e18);
        uint256 requiredCollateral = (amount * 1e18) / marketPrice;

        vm.deal(writer, requiredCollateral);
        vm.prank(writer);
        vm.expectRevert(Options.PutStrikeNotMarketPrice.selector);
        optionsContract.writePutOption{value: requiredCollateral}(amount, marketPrice + 1, premiumDue, daysToExpiry);
    }
}
