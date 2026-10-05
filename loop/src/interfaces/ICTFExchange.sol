// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @notice The slice of the LoopBet Exchange (CTF Exchange v1 fork) the BettingBankroll calls.
/// The `Order` struct mirrors `ctf-exchange/src/exchange/libraries/OrderStructs.sol`
/// field-for-field (the upstream enums are `uint8` here — ABI-identical, so the forwarded
/// `cancelOrders` selector matches the Exchange's).
interface ICTFExchange {
    struct Order {
        uint256 salt;
        address maker;
        address signer;
        address taker;
        uint256 tokenId;
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 expiration;
        uint256 nonce;
        uint256 feeRateBps;
        uint8 side;
        uint8 signatureType;
        bytes signature;
    }

    /// @notice Cancels orders. The Exchange requires `msg.sender == order.maker`, so the vault
    /// must forward this call for orders it is the maker of.
    function cancelOrders(Order[] calldata orders) external;

    /// @notice Bumps the caller's nonce, mass-invalidating every unfilled order signed at the
    /// previous nonce.
    function incrementNonce() external;
}
