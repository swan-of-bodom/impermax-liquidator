// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Test, console} from "forge-std/Test.sol";
import {ImpermaxLiquidator} from "../src/ImpermaxLiquidator.sol";
import {IBorrowable} from "../src/interfaces/IBorrowable.sol";
import {ICollateral} from "../src/interfaces/ICollateral.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IRouter03} from "../src/interfaces/IRouter.sol";

contract ImpermaxLiquidatorTest is Test {
    ImpermaxLiquidator public impermaxLiquidator;

    // Known addresses on Fantom
    address constant ROUTER = 0xd9eA4A62C46Cb221F74314C21979Cfb2E020de87;
    address constant BORROWER = 0x66EC0Da50B1B54A52817417FE1A92dF7A961d149;
    address constant UNISWAP_V2_PAIR = 0x165050d12BdA924b2C2714c890452c8833bb7403;

    function setUp() public {
        vm.createSelectFork("fantom");
        impermaxLiquidator = new ImpermaxLiquidator(ROUTER);
    }

    function test__isPositionUnderwater() public {
        bool isUnderwater = impermaxLiquidator.isPositionUnderwater(BORROWER, UNISWAP_V2_PAIR);

        assertTrue(isUnderwater, "Position not liquidatable");
    }

    // Optimal for when user is leveraged
    function test__optimalFlashRedeem() public {
        (ICollateral collateral, IBorrowable borrowable0, IBorrowable borrowable1) =
            impermaxLiquidator.router().getLendingPool(UNISWAP_V2_PAIR);

        uint256 flashAmount = impermaxLiquidator.optimalFlashRedeem(BORROWER, borrowable0, borrowable1, collateral);

        assertGt(flashAmount, 0, "Flash amount should be greater than 0");
    }

    function test__flashLiquidate() public {
        // Mock call
        address liquidatorAddress = makeAddr("someone");
        vm.startPrank(liquidatorAddress);

        (ICollateral collateral, IBorrowable borrowable0, IBorrowable borrowable1) =
            impermaxLiquidator.router().getLendingPool(UNISWAP_V2_PAIR);

        address token0 = IBorrowable(address(borrowable0)).underlying();
        address token1 = IBorrowable(address(borrowable1)).underlying();

        // Balances before
        uint256 collateralBefore = collateral.balanceOf(liquidatorAddress);
        uint256 token0Before = IERC20(token0).balanceOf(liquidatorAddress);
        uint256 token1Before = IERC20(token1).balanceOf(liquidatorAddress);

        impermaxLiquidator.flashLiquidate(BORROWER, UNISWAP_V2_PAIR);

        // Balances after
        uint256 collateralAfter = collateral.balanceOf(liquidatorAddress);
        uint256 token0After = IERC20(token0).balanceOf(liquidatorAddress);
        uint256 token1After = IERC20(token1).balanceOf(liquidatorAddress);

        // Optional: Print the profits
        console.log("Collateral profit:", collateralAfter - collateralBefore);
        console.log("Token0 profit:", token0After - token0Before);
        console.log("Token1 profit:", token1After - token1Before);

        vm.stopPrank();
    }
}
