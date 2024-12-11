// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Test, console} from "forge-std/Test.sol";
import {ImpermaxLiquidator} from "../src/ImpermaxLiquidator.sol";
import {IBorrowable} from "../src/interfaces/IBorrowable.sol";
import {ICollateral} from "../src/interfaces/ICollateral.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IRouter03} from "../src/interfaces/IRouter.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract PositionsTest is Test {
    ImpermaxLiquidator public impermaxLiquidator;

    address constant ROUTER = 0xFF8D0CDC9C857c7fA265121394558B26e1eAAffE;

    struct LendingPoolData {
        address pairId;
    }

    struct LendingPool {
        LendingPoolData lendingPool;
    }

    struct ItemsData {
        address userId;
        LendingPool borrowable;
    }

    struct Items {
        ItemsData[] items;
    }

    struct BorrowPositions {
        Items borrowPositions;
    }

    struct Data {
        BorrowPositions data;
    }

    function setUp() public {
        vm.createSelectFork("scroll");
        impermaxLiquidator = new ImpermaxLiquidator(ROUTER);
    }

    function getPositions() public view returns (string memory) {
        string memory json = vm.readFile("./test/positions.json");
        return json;
    }

    function test_getUnderwaterPositions() public {
        string memory json = getPositions();
        bytes memory positionsData = vm.parseJson(json);
        Data memory data = abi.decode(positionsData, (Data));
        ItemsData[] memory items = data.data.borrowPositions.items;
        uint256 length = items.length;

        for (uint256 i = 0; i < length; i++) {
            address uniswapV2Pair = items[i].userId;
            address borrower = items[i].borrowable.lendingPool.pairId;
            bool isUnderwater = impermaxLiquidator.isPositionUnderwater(borrower, uniswapV2Pair);

            if (isUnderwater) {
                console.log("--- Found liquidatable position ---");
                console.log("Borrower     : ", borrower);
                console.log("UniswapV2Pair: ", uniswapV2Pair);
                console.log();
                IERC20 token0 = IERC20(IPool(uniswapV2Pair).token0());
                IERC20 token1 = IERC20(IPool(uniswapV2Pair).token1());
                console.log("Underlying: ", token0.symbol(), token1.symbol());
            }
        }
    }
}
