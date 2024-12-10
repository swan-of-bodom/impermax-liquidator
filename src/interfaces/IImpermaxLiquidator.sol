// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IRouter03} from "./IRouter.sol";
import {IBorrowable} from "./IBorrowable.sol";
import {ICollateral} from "./ICollateral.sol";

interface IImpermaxLiquidator {
    error UnauthorizedCallback();
    error PositionNotLiquidatable();
    error InsufficientSeizedTokens();

    function router() external view returns (IRouter03);

    function getAccountLiquidity(
        address borrower,
        ICollateral collateral,
        IBorrowable borrowable0,
        IBorrowable borrowable1
    ) external returns (uint256 liquidity, uint256 shortfall);

    function isPositionUnderwater(
        address borrower,
        ICollateral collateral,
        IBorrowable borrowable0,
        IBorrowable borrowable1
    ) external returns (bool);

    function optimalFlashRedeem(
        address borrower,
        IBorrowable borrowable0,
        IBorrowable borrowable1,
        ICollateral collateral
    ) external returns (uint256 flashAmount, uint256 borrow0, uint256 borrow1);

    function flashLiquidate(address borrower, address uniswapV2Pair) external;

    function impermaxRedeem(address sender, uint256 redeemAmount, bytes calldata data) external;

    event FlashLiquidation(address indexed liquidator, address indexed borrower, uint256 seizedTokens, uint256 redeemAmount);

    event Liquidate(address indexed borrower, address indexed borrowable, uint256 seizedTokens);

    struct FlashCallbackData {
        address borrower;
        address uniswapV2Pair;
        ICollateral collateral;
        IBorrowable borrowable0;
        IBorrowable borrowable1;
        uint256 flashAmount;
        uint256 borrow0;
        uint256 borrow1;
    }
}
