//SPDX-License-Identifier: MIT

// What are our invariants?

//1. The total supply of DSC should always less than the total value of collateral
//2. Getter view functions should never revert

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "test/fuzz/failOnRevert/Handler.t.sol";

pragma solidity ^0.8.19;

contract Invariant is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    address whbar;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (,, weth, wbtc,whbar,,) = config.activeNetworkConfig();
        targetContract(address(dscEngine));
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));

    }

    function invariant_protocolMustHaveMoreCollateralValueThanTotalSupply() public view {
        // get the total collateral value in the protocol
        // compare it to the total supply of DSC
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

         console.log("totalSupply", totalSupply);
        console.log("wethValue", wethValue);
        console.log("wbtcValue", wbtcValue); 
        console.log("Times mint is called", handler.timesMintIsCalled());  

        assert(wethValue + wbtcValue >= totalSupply);

    }

       function invariant_gettersCantRevert() public view {
        dscEngine.getAdditionalFeedPrecision();
        dscEngine.getCollateralTokens();
        dscEngine.getLiquidationBonus();
        dscEngine.getLiquidationThreshold();
        dscEngine.getMinHealthFactor();
        dscEngine.getPrecision();
       // dscEngine.getDsc();
        // dsce.getTokenAmountFromUsd();
        // dsce.getCollateralTokenPriceFeed();
        // dsce.getCollateralBalanceOfUser();
        // getAccountCollateralValue();
    }



}