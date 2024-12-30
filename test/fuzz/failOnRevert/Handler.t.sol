//SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call functions

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

pragma solidity ^0.8.19;

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled; //Ghost variable
    address [] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;
    //MockV3Aggregator public btcUsdPriceFeed;


    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address [] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        //btcUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    
    }

    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);
        if (collateralValueInUsd == 0) {
             return;  // Exit if no collateral
        }
        int256 maxDscToMint = (int256(collateralValueInUsd/2) - int256(totalDscMinted));
        if (maxDscToMint <= 0) {
            return;
        }

        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        if (amountDscToMint == 0) {
            return;
        }

        console.log("Max DSC to mint", uint256(maxDscToMint));
        console.log("amountDscToMint", amountDscToMint);
        console.log("Collateral Value in USD", collateralValueInUsd);
        
        vm.startPrank(sender);
        dscEngine.mintDSC(amountDscToMint);
        vm.stopPrank();
        timesMintIsCalled ++; //Ghost variable
    }

    //redeem Collateral
    function depositCollateral(address collateralAddress, uint256 amountCollateral) public {
        // Convert the tokenCollateralAddress to a valid collateral token
        ERC20Mock collateralToken;
         if (address(collateralAddress) == address(weth) || address(collateralAddress) == address(wbtc)) {
            collateralToken = ERC20Mock(collateralAddress);
        } else {
        // If invalid address provided, use seed logic
            collateralToken = _getCollateralFromSeed(uint160(collateralAddress));
        }
    
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); 

        vm.startPrank(msg.sender);
        collateralToken.mint(msg.sender, amountCollateral);
        collateralToken.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateralToken), amountCollateral);
        vm.stopPrank();
        //The caveat is if the same address pushes twice
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(address collateralAddress, uint256 amountCollateral) public {
        ERC20Mock collateralToken = _getCollateralFromSeed(uint256(uint160(collateralAddress)));

        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateralToken));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateralToken), amountCollateral);
        vm.stopPrank();
    }

    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // } // This breaks our invariant test suite
    //Helper functions~
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

}