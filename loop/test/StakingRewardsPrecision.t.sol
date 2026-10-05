// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../lib/forge-std/src/Test.sol";

import {LOOP} from "../src/LOOP.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev 0.8 view of the vendored 0.5.16 StakingRewards for these tests (deployed via `deployCode`).
interface IStakingRewardsPrecision {
    function stake(uint256 amount) external;

    function getReward() external;

    function notifyRewardAmount(uint256 reward) external;

    function earned(address account) external view returns (uint256);

    function rewardRate() external view returns (uint256);

    function rewardsDuration() external view returns (uint256);
}

/// @dev Regression tests for the LOOPBET FORK of StakingRewards (REWARD_PRECISION = 1e33,
/// see src/staking/FORK.md). On the upstream 1e18 scale, with a 6-decimal reward token and
/// realistic stakes, every sub-hour interval between checkpoints floors to zero reward —
/// both tests below fail catastrophically there (payouts near 0 instead of the full share).
contract StakingRewardsPrecisionTest is Test {
    // The adversarial-scale scenario: a large staked supply sharing a modest USDC stream.
    uint256 internal constant ALICE_STAKE = 75_000_000e18;
    uint256 internal constant BOB_STAKE = 25_000_000e18;
    uint256 internal constant REWARD = 500e6; // 500 USDC over the 7-day default duration

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    /// @dev The griefer: stakes nothing, but every `getReward()` call checkpoints the
    /// global accumulator, flooring whatever accrued since the previous checkpoint.
    address internal poker = makeAddr("poker");

    MockUSDC internal usdc;
    LOOP internal loop;
    IStakingRewardsPrecision internal staking;

    function setUp() public {
        usdc = new MockUSDC();
        // 300M founder allocation funds the test stakes; the 700M side is irrelevant here.
        loop = new LOOP(makeAddr("distributor"), address(this));

        staking = IStakingRewardsPrecision(
            deployCode(
                "src/staking/StakingRewards.sol:StakingRewards",
                abi.encode(address(this), address(this), address(usdc), address(loop))
            )
        );
    }

    /* HELPERS */

    function _stake(address who, uint256 amount) internal {
        loop.transfer(who, amount);
        vm.startPrank(who);
        loop.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _notify(uint256 amount) internal {
        usdc.mint(address(staking), amount);
        staking.notifyRewardAmount(amount);
    }

    /// @dev Checkpoints the pool every hour for the whole reward period — the cheapest
    /// possible griefing pattern (zero stake, gas-only cost).
    function _pokeHourlyForFullPeriod() internal {
        uint256 duration = staking.rewardsDuration();
        for (uint256 elapsed; elapsed < duration; elapsed += 1 hours) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(poker);
            staking.getReward();
        }
    }

    /* TESTS */

    function testHourlyCheckpointGriefingDoesNotEraseRewards() public {
        _stake(alice, ALICE_STAKE + BOB_STAKE); // 100M LOOP staked
        _notify(REWARD);

        _pokeHourlyForFullPeriod();

        vm.prank(alice);
        staking.getReward();

        // The whole streamed amount (rate x duration; rate flooring costs < 1 USDC of the
        // notified 500) must reach the sole staker despite 168 hostile checkpoints.
        uint256 streamed = staking.rewardRate() * staking.rewardsDuration();
        assertGt(streamed, 499e6);
        assertApproxEqAbs(usdc.balanceOf(alice), streamed, 0.01e6);
        // The griefer earned nothing.
        assertEq(usdc.balanceOf(poker), 0);
    }

    function testProRataSplitSurvivesHourlyCheckpoints() public {
        _stake(alice, ALICE_STAKE);
        _stake(bob, BOB_STAKE);
        _notify(REWARD);

        _pokeHourlyForFullPeriod();

        vm.prank(alice);
        staking.getReward();
        vm.prank(bob);
        staking.getReward();

        uint256 streamed = staking.rewardRate() * staking.rewardsDuration();
        // 75M : 25M split — 3:1, exact within truncation dust.
        assertApproxEqAbs(usdc.balanceOf(alice), (streamed * 3) / 4, 0.01e6);
        assertApproxEqAbs(usdc.balanceOf(bob), streamed / 4, 0.01e6);
    }
}
