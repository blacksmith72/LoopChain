// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @notice The slice of the Gnosis ConditionalTokens framework the BettingBankroll calls.
/// @dev The TreasuryVault used to import this too; since 2026-08-20 it does not touch the CTF
/// at all (the fill-time fee path is retired and its ERC-1155 receiver hooks are gone).
interface IConditionalTokens {
    /// @notice Burns the caller's outcome tokens of a resolved condition and pays out collateral.
    /// @param collateralToken The collateral (USDC).
    /// @param parentCollectionId Zero for top-level positions (always, in LoopBet markets).
    /// @param conditionId The resolved condition.
    /// @param indexSets Outcome index sets; `[1, 2]` redeems both the YES and NO slots.
    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
}
