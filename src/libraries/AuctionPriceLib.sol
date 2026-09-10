// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AuctionPriceLib
/// @notice Converts a Continuous Clearing Auction price into a Uniswap v4 initialization price.
/// @dev The arithmetic mirrors `TokenPricing` in the Uniswap liquidity launcher exactly, so a pool
///      that KAY9Genesis initializes during recovery is priced identically to one the LBPStrategy
///      would have initialized. Auction prices are Q96 raw-currency per raw-token.
library AuctionPriceLib {
    /// @notice Thrown when the auction price is zero.
    error PriceIsZero();

    /// @notice Thrown when the inverted price does not fit a uint160.
    /// @param price The offending price.
    error PriceTooHigh(uint256 price);

    /// @notice Thrown when the derived sqrt price falls outside the v4 bounds.
    /// @param sqrtPriceX96 The offending sqrt price.
    error SqrtPriceOutOfBounds(uint160 sqrtPriceX96);

    /// @notice The Q192 fixed-point scale used for the intermediate price.
    uint256 internal constant Q192 = 1 << 192;

    /// @notice Converts a Q96 currency-per-token price into v4's currency1-per-currency0 Q192 price.
    /// @param price The auction price in Q96 currency-per-token.
    /// @param currencyIsCurrency0 True when the raise currency sorts before the token.
    /// @return priceX192 The Q192 price of currency1 in terms of currency0.
    function convertToPriceX192(uint256 price, bool currencyIsCurrency0) internal pure returns (uint256 priceX192) {
        if (price == 0) revert PriceIsZero();
        if (currencyIsCurrency0) {
            if ((Q192 / price) >> 160 != 0) revert PriceTooHigh(Q192 / price);
            priceX192 = FullMath.mulDiv(Q192, FixedPoint96.Q96, price);
        } else {
            if (price >> 160 != 0) revert PriceTooHigh(price);
            priceX192 = price << FixedPoint96.RESOLUTION;
        }
    }

    /// @notice Converts a Q192 price into a v4 sqrtPriceX96.
    /// @param priceX192 The Q192 price.
    /// @return sqrtPriceX96 The initialization price.
    function convertToSqrtPriceX96(uint256 priceX192) internal pure returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceOutOfBounds(sqrtPriceX96);
        }
    }

    /// @notice One-step conversion from an auction price to a v4 initialization price.
    /// @param price The auction price in Q96 currency-per-token.
    /// @param currencyIsCurrency0 True when the raise currency sorts before the token.
    /// @return The initialization sqrtPriceX96.
    function toSqrtPriceX96(uint256 price, bool currencyIsCurrency0) internal pure returns (uint160) {
        return convertToSqrtPriceX96(convertToPriceX192(price, currencyIsCurrency0));
    }

    /// @notice The fully diluted valuation implied by an auction floor price, in wei.
    /// @dev `floorPriceQ96` is wei of ETH per wei of KAY9, so multiplying by the whole supply in
    ///      wei and dividing by 2^96 yields the FDV in wei.
    /// @param floorPriceQ96 The Q96 floor price.
    /// @param totalSupplyWei The token supply in wei.
    /// @return The implied FDV in wei.
    function impliedFdvWei(uint256 floorPriceQ96, uint256 totalSupplyWei) internal pure returns (uint256) {
        return FullMath.mulDiv(floorPriceQ96, totalSupplyWei, FixedPoint96.Q96);
    }

    /// @notice The Q96 price that expresses a target fully diluted valuation.
    /// @param fdvWei The target FDV in wei of ETH.
    /// @param totalSupplyWei The token supply in wei.
    /// @return The Q96 price.
    function fdvWeiToPriceQ96(uint256 fdvWei, uint256 totalSupplyWei) internal pure returns (uint256) {
        return FullMath.mulDiv(fdvWei, FixedPoint96.Q96, totalSupplyWei);
    }
}
