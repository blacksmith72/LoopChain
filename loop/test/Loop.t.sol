// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../lib/forge-std/src/Test.sol";

import {LOOP} from "../src/LOOP.sol";

contract LoopTest is Test {
    address internal distributor = makeAddr("distributor");
    address internal founders = makeAddr("founders");

    LOOP internal loop;

    function setUp() public {
        loop = new LOOP(distributor, founders);
    }

    function testGenesisSupplyAndSplit() public {
        assertEq(loop.totalSupply(), 1_000_000_000e18);
        assertEq(loop.balanceOf(distributor), 700_000_000e18);
        assertEq(loop.balanceOf(founders), 300_000_000e18);

        // The constants are self-consistent.
        assertEq(loop.COMMUNITY_SUPPLY() + loop.FOUNDERS_SUPPLY(), loop.TOTAL_SUPPLY());
    }

    function testMetadata() public {
        assertEq(loop.name(), "LOOP");
        assertEq(loop.symbol(), "LOOP");
        assertEq(loop.decimals(), 18);
    }

    function testConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert(bytes("LOOP: distributor is zero"));
        new LOOP(address(0), founders);

        vm.expectRevert(bytes("LOOP: founders is zero"));
        new LOOP(distributor, address(0));
    }

    function testTransferableDayOne(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != founders && to != distributor);
        amount = bound(amount, 0, loop.balanceOf(founders));

        vm.prank(founders);
        loop.transfer(to, amount);

        assertEq(loop.balanceOf(to), amount);
    }

    function testPermit() public {
        (address holder, uint256 holderKey) = makeAddrAndKey("holder");
        address spender = makeAddr("spender");
        uint256 amount = 1_000e18;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(founders);
        loop.transfer(holder, amount);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                holder,
                spender,
                amount,
                loop.nonces(holder),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", loop.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderKey, digest);

        loop.permit(holder, spender, amount, deadline, v, r, s);

        assertEq(loop.allowance(holder, spender), amount);

        vm.prank(spender);
        loop.transferFrom(holder, spender, amount);
        assertEq(loop.balanceOf(spender), amount);
    }
}
