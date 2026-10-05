// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol";

import {ICTFExchange} from "../../src/interfaces/ICTFExchange.sol";

/// @dev Minimal Exchange stand-in for vault Phase 2 tests: consumes the vault's USDC allowance
/// the way a fill does (`transferFrom`), tracks nonces/cancels like the real NonceManager/Trading
/// mixins, and calls `isValidSignature` from its own address the way the fork's
/// `verifyPoly1271Signature` does (so `msg.sender` inside the vault is the exchange).
contract MockExchange {
    IERC20 public immutable usdc;

    mapping(address => uint256) public nonces;
    uint256 public cancelledCount;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    /// @dev Simulates the maker-side USDC pull of a fill.
    function pull(address from, uint256 amount) external {
        usdc.transferFrom(from, address(this), amount);
    }

    function cancelOrders(ICTFExchange.Order[] calldata orders) external {
        for (uint256 i = 0; i < orders.length; i++) {
            require(orders[i].maker == msg.sender, "NotOwner");
            cancelledCount++;
        }
    }

    function incrementNonce() external {
        nonces[msg.sender]++;
    }

    /// @dev The real exchange validates ERC-1271 orders via a staticcall from itself.
    function checkSignature(address maker, bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return IERC1271(maker).isValidSignature(hash, signature);
    }
}
