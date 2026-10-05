// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title LOOP
/// @notice The LoopBet token. OpenZeppelin ERC-20 + Permit and nothing else: the total supply is
/// fixed at 1B, minted once at genesis, and the contract has ZERO admin functions — nothing to own,
/// pause, mint, or upgrade.
/// @dev Genesis split (verifiable on-chain from the deployment transaction forever):
/// 700M → the emissions distributor (the community supply, earnable only by betting; the
/// distributor cannot release it except through Merkle claims) and 300M → founders/team.
contract LOOP is ERC20, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant COMMUNITY_SUPPLY = 700_000_000e18;
    uint256 public constant FOUNDERS_SUPPLY = 300_000_000e18;

    /// @param distributor The emissions distributor that receives the 700M community supply.
    /// @param founders The founders/team address that receives the 300M allocation.
    constructor(address distributor, address founders) ERC20("LOOP", "LOOP") ERC20Permit("LOOP") {
        require(distributor != address(0), "LOOP: distributor is zero");
        require(founders != address(0), "LOOP: founders is zero");

        _mint(distributor, COMMUNITY_SUPPLY);
        _mint(founders, FOUNDERS_SUPPLY);
    }
}
