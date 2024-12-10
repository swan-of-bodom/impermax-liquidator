// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {IBorrowable} from "./interfaces/IBorrowable.sol";
import {ICollateral} from "./interfaces/ICollateral.sol";
import {IRouter03} from "./interfaces/IRouter.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IImpermaxLiquidator} from "./interfaces/IImpermaxLiquidator.sol";

contract ImpermaxLiquidator is IImpermaxLiquidator {
    /// @inheritdoc IImpermaxLiquidator
    IRouter03 public immutable router;

    constructor(address _router) {
        /// The Impermax router, based on the type of pools we're liquidating (ie. stable/v2v2/sol_v2/etc.)
        router = IRouter03(_router);
    }

    /// @inheritdoc IImpermaxLiquidator
    function flashLiquidate(address borrower, address uniswapV2Pair) external {
        // Get lending pool for this pair
        (ICollateral collateral, IBorrowable borrowable0, IBorrowable borrowable1) =
            router.getLendingPool(uniswapV2Pair);

        // Accrue interest in borrowables and check if position is liquidatable
        if (!isPositionUnderwater(borrower, collateral, borrowable0, borrowable1)) revert PositionNotLiquidatable();

        // Calculate optimal amount of UniswapV2Pair to flash redeem
        (uint256 flashAmount, uint256 borrow0, uint256 borrow1) =
            optimalFlashRedeem(borrower, borrowable0, borrowable1, collateral);

        bytes memory data = abi.encode(
            FlashCallbackData({
                borrower: borrower,
                uniswapV2Pair: uniswapV2Pair,
                collateral: collateral,
                borrowable0: borrowable0,
                borrowable1: borrowable1,
                flashAmount: flashAmount,
                borrow0: borrow0,
                borrow1: borrow1
            })
        );

        // Flash redeem stakedLP tokens back to this contract
        collateral.flashRedeem(address(this), flashAmount, data);
    }

    /// @inheritdoc IImpermaxLiquidator
    function impermaxRedeem(address sender, uint256 redeemAmount, bytes calldata data) external {
        // Shh
        sender;

        FlashCallbackData memory calleeData = abi.decode(data, (FlashCallbackData));
        if (msg.sender != address(calleeData.collateral)) revert UnauthorizedCallback();

        IPool pair = IPool(ICollateral(calleeData.uniswapV2Pair).underlying());

        // 1. Convert stakedLP into LP tokens
        IERC20(calleeData.uniswapV2Pair).transfer(calleeData.uniswapV2Pair, redeemAmount);
        ICollateral(calleeData.uniswapV2Pair).redeem(address(pair));

        // 2. Convert LP tokens to underlying tokens
        (uint256 repayAmount0, uint256 repayAmount1) = pair.burn(address(this));

        // Get token addresses
        address token0 = pair.token0();
        address token1 = pair.token1();

        // 3. Liquidate positions on both borrowables and receive collateral tokens.
        uint256 seizedTokens = _liquidatePositions(calleeData, token0, token1, repayAmount0, repayAmount1);
        if (seizedTokens == 0) revert InsufficientSeizedTokens();

        // 4. Return the equivalent of the flash loaned LP in collateral tokens (`flashRedeem` rounds up)
        //    `seizedTokens` / `redeemAmount` = liquidation incentive
        calleeData.collateral.transfer(msg.sender, redeemAmount + 1);

        // 5. Send profit to liquidator
        _sendProfit(calleeData.collateral, token0, token1);

        emit FlashLiquidation(tx.origin, calleeData.borrower, seizedTokens, redeemAmount);
    }

    /// @inheritdoc IImpermaxLiquidator
    function isPositionUnderwater(
        address borrower,
        ICollateral collateral,
        IBorrowable borrowable0,
        IBorrowable borrowable1
    ) public returns (bool) {
        (, uint256 shortfall) = getAccountLiquidity(borrower, collateral, borrowable0, borrowable1);
        return shortfall > 0;
    }

    /// @inheritdoc IImpermaxLiquidator
    function getAccountLiquidity(
        address borrower,
        ICollateral collateral,
        IBorrowable borrowable0,
        IBorrowable borrowable1
    ) public returns (uint256 liquidity, uint256 shortfall) {
        borrowable0.accrueInterest();
        borrowable1.accrueInterest();
        (liquidity, shortfall) = collateral.accountLiquidity(borrower);
    }

    /// @inheritdoc IImpermaxLiquidator
    function optimalFlashRedeem(
        address borrower,
        IBorrowable borrowable0,
        IBorrowable borrowable1,
        ICollateral collateral
    ) public returns (uint256 flashAmount, uint256 borrow0, uint256 borrow1) {
        // Get the underlying LP token and pool
        ICollateral stakedLPToken = ICollateral(collateral.underlying());
        IPool pool = IPool(stakedLPToken.underlying());

        // Get current reserves and total supply
        (uint256 reserve0, uint256 reserve1,) = pool.getReserves();
        uint256 totalSupply = IERC20(address(pool)).totalSupply();

        // Get borrow balances
        borrow0 = borrowable0.borrowBalance(borrower);
        borrow1 = borrowable1.borrowBalance(borrower);

        uint256 lpNeededForToken0 = (borrow0 * totalSupply) / reserve0;
        uint256 lpNeededForToken1 = (borrow1 * totalSupply) / reserve1;

        // Min of the two amounts ensures we have no amount of token0 or token1 after the liquidation
        flashAmount = lpNeededForToken0 > lpNeededForToken1 ? lpNeededForToken1 : lpNeededForToken0;

        // Amount of stakedLP we need, take into account the liq. penalty and exchange rate
        flashAmount = ((flashAmount * 1e18) / collateral.liquidationPenalty() * 1e18) / stakedLPToken.exchangeRate();

        return (flashAmount, borrow0, borrow1);
    }

    //
    // Internal
    //

    /// Checks allowance and approves if necessary
    function _approve(IERC20 token, uint256 amount) internal {
        if (token.allowance(address(this), address(router)) >= amount) return;
        token.approve(address(router), type(uint256).max);
    }

    // Liquidate all positions
    function _liquidatePositions(
        FlashCallbackData memory data,
        address token0,
        address token1,
        uint256 repayAmount0,
        uint256 repayAmount1
    ) internal returns (uint256 totalProfit) {
        if (data.borrow0 >= data.borrow1) {
            totalProfit += _liquidatePosition(data.borrower, data.borrowable0, token0, repayAmount0);
            totalProfit += _liquidatePosition(data.borrower, data.borrowable1, token1, repayAmount1);
        } else {
            totalProfit += _liquidatePosition(data.borrower, data.borrowable1, token1, repayAmount1);
            totalProfit += _liquidatePosition(data.borrower, data.borrowable0, token0, repayAmount0);
        }

        return totalProfit;
    }

    // Liquidates a single position
    function _liquidatePosition(address borrower, IBorrowable borrowable, address token, uint256 repayAmount)
        internal
        returns (uint256 seizedTokens)
    {
        if (repayAmount > 0) {
            IERC20(token).approve(address(router), repayAmount);

            (, seizedTokens) =
                router.liquidate(address(borrowable), repayAmount, borrower, address(this), block.timestamp);

            emit Liquidate(borrower, address(borrowable), seizedTokens);
        }
        return seizedTokens;
    }

    // To be called after any flash liquidation
    function _sendProfit(ICollateral collateral, address token0, address token1) internal {
        // The profit should be equal to: `seizedTokens` - `redeemAmount`
        uint256 profit = collateral.balanceOf(address(this));
        if (profit > 0) collateral.transfer(tx.origin, profit);

        // Check for dust
        uint256 token0Balance = IERC20(token0).balanceOf(address(this));
        uint256 token1Balance = IERC20(token1).balanceOf(address(this));

        if (token0Balance > 0) IERC20(token0).transfer(tx.origin, token0Balance);
        if (token1Balance > 0) IERC20(token1).transfer(tx.origin, token1Balance);
    }
}
