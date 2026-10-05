// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { OrderStatus, Order } from "../libraries/OrderStructs.sol";

interface ITradingEE {
    /// @notice LOOPBET FORK: thrown when the immutable feeRecipient is the zero address at
    /// construction (fees would be unroutable — every fee-bearing fill would revert).
    error InvalidFeeRecipient();

    error NotOwner();
    error NotTaker();
    error OrderFilledOrCancelled();
    error OrderExpired();
    error InvalidNonce();
    error MakingGtRemaining();
    error NotCrossing();
    error TooLittleTokensReceived();
    error MismatchedTokenIds();

    /// @notice Emitted when an order is cancelled
    event OrderCancelled(bytes32 indexed orderHash);

    /// @notice Emitted when an order is filled
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    );

    /// @notice Emitted when a set of orders is matched
    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        address indexed takerOrderMaker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    );
}

interface ITrading is ITradingEE { }
