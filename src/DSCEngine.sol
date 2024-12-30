// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
//errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";

/**
 * @title DecentralizedStableCoin
 * @author Dennis Kilonzo
 *
 * The system is designed to be as minimal as possible and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties
 * - Exogenous collateral
 * -Dollar pegged
 * -Algorithmically stable
 *
 * It is similar to DAI if had no presence of governance, no fees and was only backed by wrapped Eth and wrapped Bitcoin.
 *
 * Our DSC system should always be "overcollateralized". At no point should our collateral value <= all of our $ backed DSC value.
 *
 * @notice This contract is the core of the DSC sstem. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawring collateral.
 * @notice This contract is lossely based on the MAkerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard{
    //////////////////////////////////
    //Errors //
    //////////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeOfSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsNotBroken();
    error DSCEngine__HealthFactorIsNotImproved();
    error DSCEngine__HealthFactorOk();

    //////////////////////////////////
    //Types//
    //////////////////////////////////
    using OracleLib for AggregatorV3Interface;

    //////////////////////////////////
    //State Variables  //
    //////////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTHFACTOR = 1e18;

    mapping(address token => address priceFeed) private s_tokenToPriceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_CollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////////// 
    //Events  //
    //////////////////////////////////
    event CollateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );

    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed tokenCollateralAddress, uint256 amountCollateral);

    ///////////////////////////////////
    //Modifier  //
    ///////////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();

        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////////////////////
    //Functions //////////////////////
    //////////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeOfSameLength();
        }
        //We use USD PriceFeeds e.g; BTC/USD, ETH/USD, etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_tokenToPriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////////////
    //EXternal Functions //
    //////////////////////////////////

    /*
     * @param atokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of the token to be deposited as collateral
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function deposits collateral and mints DSC at once
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) public {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress: Address of the collateral token
     * @param amountCollateral: Amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /** 
     * @param tokenCollateralAddress The address of the token to be redeemed as collateral
     * @param amountCollateral The amount of the token to be redeemed as collateral
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function redeems collateral and burns DSC at once
     */ 

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) public {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral); 
        //redeemCollateral already checks health factor
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _revertIfHealthFactorIsBroken(msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice follows CEI pattern
     * @param amountDscToMint The amount of Decentralized Stablecoin to mint.
     * @notice They must have more collateral value than the minimum threshhold
     */

    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;

        //if they minted too much($150 DSC, $100ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }


    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //I don't think this would ever hit
    }

    function calculateHealthFactor(address user) public view returns (uint256) {
        return _calculateHealthFactor(user);
    }

    /**
     * @param collateral The collateral token to liquidate
     * @param user The user who has broken the health factor. Their _healthFactor should be below the MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve user health factor
     * @notice Yo can partially liquidate a user
     * @notice You will get a liquidation bonus for taking a user's funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A common bug would be if the protocol were 100% or less collateralized, then we woon't be able to incentivie liquidators
     * For example, if he collateral price plumeted before anyone could liquidate
     * Follow CEI
     */

    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = _calculateHealthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTHFACTOR) {
            revert DSCEngine__HealthFactorIsNotBroken();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //we want to give them a 10% bonus
        //So we are giving them 110WETH for 100DSC liquidated
        //We should add a feature to liquidate in the event the protocol is insolvent
        //And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //We need to burn DSC
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _calculateHealthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorIsNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////////
    //Private and Internal Functions //
    /////////////////////////////////////
      /**
     * @dev Low-level internal function, do not call unless function calling 
     * it is checking for health factors being broken amount
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[address(onBehalfOf)] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);  
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_CollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to,  tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter(). Rare case in which we breach the CEI pattern
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(! success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _calculateHealthFactor(user);
        if (userHealthFactor < MIN_HEALTHFACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to the liquidation a user is
     * If a user goes below 1, then they get liquidated
     */
    function _calculateHealthFactor(address user) internal view returns (uint256) {
        //totalDSC minted
        //total collateral value to make sure they have enough collateral
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
         if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /////////////////////////////////////
    //Public & External View Functions //
    /////////////////////////////////////
     function getHealthFactor(address user) external view returns(uint256) {
        return _calculateHealthFactor(user);
     }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTHFACTOR;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //we need to get the price of the token
        // The price of the token will help us get the amount
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        uint256 tokenAmount = (usdAmountInWei * PRECISION)/(uint256 (price) * ADDITIONAL_FEED_PRECISION);
        return (tokenAmount);
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalcollateralValueInUsd) {
        //loop through each collateral token get the amount they have deposited and map it to price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_CollateralDeposited[user][token];
            totalcollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalcollateralValueInUsd;
    }

    function getCollateralTokenPriceFeed(address token) public view returns (address) {
        return s_tokenToPriceFeeds[token];
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //The amount returned will be in 8 decimal places(amount *1e8)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = (_getAccountInformation(user));
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address tokenCollateralAddress) external view returns (uint256) {
        return s_CollateralDeposited[user][tokenCollateralAddress];
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    
}
