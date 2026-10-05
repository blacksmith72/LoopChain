// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal ConditionalTokens stand-in: `redeemPositions` pays the caller a preconfigured
/// USDC amount per condition, mimicking the redemption of resolved positions. Operator
/// approvals are tracked (never granted by our contracts) so the BUY-only property — "the
/// Exchange is never approved to move our outcome tokens" — is assertable in tests.
contract MockConditionalTokens {
    mapping(bytes32 => uint256) public payouts;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setPayout(bytes32 conditionId, uint256 amount) external {
        payouts[conditionId] = amount;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function redeemPositions(
        address collateralToken,
        bytes32, /* parentCollectionId */
        bytes32 conditionId,
        uint256[] calldata /* indexSets */
    ) external {
        uint256 amount = payouts[conditionId];
        payouts[conditionId] = 0;
        if (amount > 0) IERC20(collateralToken).transfer(msg.sender, amount);
    }
}
