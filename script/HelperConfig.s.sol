//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address hbarUsdPriceFeed; // New
        address weth;
        address wbtc;
        address whbar; // New
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    int256 public constant HBAR_USD_PRICE = 500e8; // New
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) { // Sepolia
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 296) { // Hedera Testnet
            activeNetworkConfig = getHederaTestnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    // New Hedera Testnet configuration
    function getHederaTestnetConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: address(0), // No WETH on Hedera
            wbtcUsdPriceFeed: address(0), // No WBTC on Hedera
            hbarUsdPriceFeed: 0x59bC155EB6c6C415fE43255aF66EcF0523c92B4a, // HBAR/USD
            weth: address(0), // Not used
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063, // Not used
            whbar: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81, // WHBAR ERC20
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            hbarUsdPriceFeed: address(0), // No HBAR on Sepolia
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            whbar: address(0), // Not used
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        // Existing mocks
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        ERC20Mock wethMock = new ERC20Mock("Wrapped Ethereum", "WETH");
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wbtcMock = new ERC20Mock("Wrapped Bitcoin", "WBTC");
        
        // New HBAR mocks
        MockV3Aggregator hbarUsdPriceFeed = new MockV3Aggregator(DECIMALS, HBAR_USD_PRICE);
        ERC20Mock whbarMock = new ERC20Mock("Wrapped HBAR", "WHBAR");
        vm.stopBroadcast();

        return NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            hbarUsdPriceFeed: address(hbarUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            whbar: address(whbarMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}