// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Options} from "../src/Options.sol";
//import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DeployOptions is Script {
    // Environment variable keys
    string private constant DAI_ADDRESS_KEY = "DAI_ADDRESS";
    string private constant PRICE_FEED_ADDRESS_KEY = "PRICE_FEED_ADDRESS";

    function run() external {
        // Load private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        if (deployerPrivateKey == 0) {
            revert("PRIVATE_KEY not set in .env file");
        }

        // Load constructor arguments from environment
        address daiAddress = vm.envAddress(DAI_ADDRESS_KEY);
        address priceFeedAddress = vm.envAddress(PRICE_FEED_ADDRESS_KEY);

        // Validate addresses
        if (daiAddress == address(0)) {
            revert("DAI_ADDRESS not set or invalid");
        }
        if (priceFeedAddress == address(0)) {
            revert("PRICE_FEED_ADDRESS not set or invalid");
        }

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy Options contract
        Options options = new Options(daiAddress, priceFeedAddress);
        console.log("Options contract deployed at:", address(options));

        // Stop broadcasting
        vm.stopBroadcast();

        // Log additional info for verification
        console.log("Deployer address:", msg.sender);
        console.log("Chain ID:", block.chainid);
    }
}