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

    /// The Impermax router, based on the type of pools we're liquidating (ie. stable/v2v2/sol_v2/etc.)
    constructor(address _router) {
        router = IRouter03(_router);
    }

    /// @inheritdoc IImpermaxLiquidator
    function flashLiquidate(address borrower, address uniswapV2Pair) external {
        // Get lending pool for this pair
        (ICollateral collateral, IBorrowable borrowable0, IBorrowable borrowable1) = getLendingPool(uniswapV2Pair);

        // Accrue interest in borrowables and check if position is liquidatable
        if (!_isPositionUnderwater(borrower, collateral, borrowable0, borrowable1)) revert PositionNotLiquidatable();

        // Calculate optimal amount of UniswapV2Pair to flash redeem, must be leveraged (ie. borrowed both tokens)
        uint256 flashAmount = optimalFlashRedeem(borrower, borrowable0, borrowable1, collateral);
        if (flashAmount == 0) revert InsufficientFlashAmount();

        bytes memory data = abi.encode(
            FlashCallbackData({
                borrower: borrower,
                uniswapV2Pair: uniswapV2Pair,
                collateral: collateral,
                borrowable0: borrowable0,
                borrowable1: borrowable1,
                flashAmount: flashAmount
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

        // 4. Return the equivalent of the flash loaned LP to the collateral (`flashRedeem` rounds up)
        //    `seizedTokens` / `redeemAmount` = liquidation incentive
        calleeData.collateral.transfer(msg.sender, redeemAmount + 1);

        // 5. Send collateral profit to liquidator
        calleeData.collateral.transfer(tx.origin, seizedTokens - redeemAmount - 1);

        /// @custom:event FlashLiquidate
        emit FlashLiquidate(tx.origin, calleeData.borrower, seizedTokens, redeemAmount);
    }

    /// @inheritdoc IImpermaxLiquidator
    function isPositionUnderwater(address borrower, address uniswapV2Pair) external returns (bool) {
        // Get lending pool for this pair
        (ICollateral collateral, IBorrowable borrowable0, IBorrowable borrowable1) = getLendingPool(uniswapV2Pair);

        // True if user has shortfall
        return _isPositionUnderwater(borrower, collateral, borrowable0, borrowable1);
    }

    //
    // Public
    //

    /// @inheritdoc IImpermaxLiquidator
    function getLendingPool(address uniswapV2Pair) public view returns (ICollateral, IBorrowable, IBorrowable) {
        return router.getLendingPool(uniswapV2Pair);
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
    ) public returns (uint256 flashAmount) {
        // Get the underlying LP token and pool
        ICollateral stakedLPToken = ICollateral(collateral.underlying());
        IPool pool = IPool(stakedLPToken.underlying());

        // Get current reserves and total supply
        (uint256 reserve0, uint256 reserve1,) = pool.getReserves();
        uint256 totalSupply = IERC20(address(pool)).totalSupply();

        // Get borrow balances
        uint256 borrow0 = borrowable0.borrowBalance(borrower);
        uint256 borrow1 = borrowable1.borrowBalance(borrower);

        uint256 lpNeededForToken0 = (borrow0 * totalSupply) / reserve0;
        uint256 lpNeededForToken1 = (borrow1 * totalSupply) / reserve1;

        // Min of the two amounts ensures we have no amount of token0 and token1 after the liquidation
        flashAmount = lpNeededForToken0 > lpNeededForToken1 ? lpNeededForToken1 : lpNeededForToken0;

        // Amount of stakedLP we need, take into account the liq. penalty and exchange rate
        return (flashAmount * 1e36) / (collateral.liquidationPenalty() * stakedLPToken.exchangeRate());
    }

    //
    // Internal
    //

    /// Checks allowance and approves if necessary
    function _approve(address token, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), address(router)) >= amount) return;
        IERC20(token).approve(address(router), type(uint256).max);
    }

    /// Returns whether positions can be liquidated or not
    function _isPositionUnderwater(
        address borrower,
        ICollateral collateral,
        IBorrowable borrowable0,
        IBorrowable borrowable1
    ) internal returns (bool) {
        (, uint256 shortfall) = getAccountLiquidity(borrower, collateral, borrowable0, borrowable1);
        return shortfall > 0;
    }

    // Liquidate all positions
    function _liquidatePositions(
        FlashCallbackData memory data,
        address token0,
        address token1,
        uint256 repayAmount0,
        uint256 repayAmount1
    ) internal returns (uint256 seizedCollateral) {
        // NOTE: Adjust by decimals?
        if (repayAmount0 >= repayAmount1) {
            seizedCollateral += _liquidatePosition(data.borrower, data.borrowable0, token0, repayAmount0);
            seizedCollateral += _liquidatePosition(data.borrower, data.borrowable1, token1, repayAmount1);
        } else {
            seizedCollateral += _liquidatePosition(data.borrower, data.borrowable1, token1, repayAmount1);
            seizedCollateral += _liquidatePosition(data.borrower, data.borrowable0, token0, repayAmount0);
        }

        return seizedCollateral;
    }

    // Liquidates a single position, event kept for reporting purposes for new functions.
    function _liquidatePosition(address borrower, IBorrowable borrowable, address token, uint256 repayAmount)
        internal
        returns (uint256 seizedTokens)
    {
        if (repayAmount > 0) {
            // Approve router if neeeded
            _approve(token, repayAmount);

            // Liquidate and receive collateral
            (, seizedTokens) =
                router.liquidate(address(borrowable), repayAmount, borrower, address(this), block.timestamp);

            /// @custom:event Liquidate
            emit Liquidate(borrower, address(borrowable), seizedTokens);
        }

        return seizedTokens;
    }
}
