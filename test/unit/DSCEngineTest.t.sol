//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";


contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address hbarUsdPriceFeed;
    address whbar;
    address weth;
    address wbtc;
    address [] public tokenAddresses;
    address [] public priceFeedAddresses;

    address public USER = makeAddr("User");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100e18;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;
    uint256 private constant PRECISION = 1e18;


    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, hbarUsdPriceFeed, weth, wbtc, whbar,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
    }

    //////////////////////////////////
    //ConstructorTest////////////////
    //////////////////////////////////

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeOfSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////////////////
    //Price Test//////////////////////
    //////////////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15 ether;
        //15e18 * 2000 = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assert(expectedUsd == actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assert(expectedWeth == actualWeth);
    }

    //////////////////////////////////
    //depositCollateral Test//////////
    //////////////////////////////////
    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);

        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN");
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);   
    }

    function testCanRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testMintDscSuccessful() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        // Calculate maximum DSC that can be minted
        // 10 ETH * $2000 = $20,000 total collateral value
        // With 50% liquidation threshold, can mint up to $10,000 DSC
        uint256 startingDscBalance = 0;
        // Mint half of the maximum allowed 
        uint256 amountToMint = AMOUNT_TO_MINT;// Adjust for price feed decimals

        uint256 endingDscBalance = dsc.balanceOf(USER);
        assertEq(endingDscBalance, startingDscBalance + amountToMint);
        vm.stopPrank();
    }

    // function testRevertsIfMintedDscBreaksHealthFactor() public {
    //     (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
    //     uint256 amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

    //     uint256 expectedHealthFactor =
    //         dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
    //     dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    //     vm.stopPrank();
    // }


    function testMintAmountIsMoreThanZero() public {
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.mintDSC(0);
        vm.stopPrank();
    }


    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }


    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.burnDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0); 
    }


    function testCantBurnMoreThanUserHas() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        
        uint256 amountToBurn = AMOUNT_TO_MINT + 1; // Try to burn more than minted

        dsc.approve(address(dscEngine), amountToBurn);
        vm.expectRevert();
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    //////////////////////////////////
    //HealthFactor Test//////////
    //////////////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
    
        console.log("Amount Collateral (in ETH):", AMOUNT_COLLATERAL / 1e18);
        console.log("Amount to Mint (DSC):", AMOUNT_TO_MINT);
        console.log("Total DSC Minted:", totalDscMinted);
        console.log("Collateral Value in USD:", collateralValueInUsd);
        console.log("Actual Health Factor:", healthFactor);
    
        // Let's calculate expected step by step
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        console.log("Collateral Adjusted for Threshold:", collateralAdjustedForThreshold);
    
        uint256 expectedHealthFactor = 100 * 1e18;
        console.log("Expected Health Factor:", expectedHealthFactor);
    
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        //180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == PRECISION * 9 / 10); //[FAIL: panic: assertion failed (0x01)]
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    //////////////////////////////////
    //Liquidation Test/////////////////
    //////////////////////////////////
    function testSuccessfulLiquidation() public {
        // Setup: User deposits collateral and mints DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        // Simulate price drop to break health factor
        int256 newPrice = 19e8; // 50% price drop
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(newPrice);
        vm.stopPrank();

        // Liquidator setup
        vm.startPrank(LIQUIDATOR);
        // Mint DSC for liquidator (you'll need to implement this based on your setup)
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(address(weth), COLLATERAL_TO_COVER, AMOUNT_TO_MINT);

        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        
        uint256 userInitialCollateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        uint256 userInitialHealthFactor = dscEngine.getHealthFactor(USER);

        console.log("User initial collateral in DSCEngine:", userInitialCollateralBalance);
        console.log(" User Initial Health Factor:", userInitialHealthFactor);
    

    // Perform liquidation
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT);

    // Check final collateral balances
        uint256 userFinalCollateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        uint256 userFinalHealthFactor = dscEngine.getHealthFactor(USER);

        console.log("User final collateral in DSCEngine:", userFinalCollateralBalance);
        console.log("User Final Health Factor:", userFinalHealthFactor);

    // Verify collateral transfer
        assert(userFinalCollateralBalance < userInitialCollateralBalance);
        assert(userFinalHealthFactor > userInitialHealthFactor);

        vm.stopPrank();
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dscEngine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }


    modifier liquidated() {//has a problem
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsNotBroken.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    } 

   function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
    
         // Let's log intermediate values
        uint256 tokenAmount = dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT);
         console.log("Base token amount:", tokenAmount);
    
         uint256 bonusCollateral = (tokenAmount * dscEngine.getLiquidationBonus()) / 100;
        console.log("Bonus amount:", bonusCollateral);
    
        uint256 expectedWeth = tokenAmount + bonusCollateral;
        console.log("Expected total:", expectedWeth);
        console.log("Actual balance:", liquidatorWethBalance);
    
         // Instead of using the hardcoded value, let's calculate it
        assertEq(liquidatorWethBalance, expectedWeth);

    } // [FAIL: assertion failed: 5 != 6111111111111111110]

    // function testUserStillHasSomeEthAfterLiquidation() public liquidated {
    //     // Get how much WETH the user lost
    //     uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT);
    //         //+ (dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dscEngine.getLiquidationBonus());

    //     uint256 usdAmountLiquidated = dscEngine.getUsdValue(weth, amountLiquidated);
    //     uint256 expectedUserCollateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

    //     (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(USER);
    //     uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
    //     assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
    //     assertEq(userCollateralValueInUsd, hardCodedExpectedValue); 
    // }
    

}
