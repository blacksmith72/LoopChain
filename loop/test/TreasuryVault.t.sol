// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../lib/forge-std/src/Test.sol";

import {TimelockController} from "../lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {LOOP} from "../src/LOOP.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {IStakingRewardsMinimal} from "../src/interfaces/IStakingRewardsMinimal.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The 0.8 view of the vendored 0.5.16 StakingRewards, for test interactions beyond
/// what the vault needs (stake/withdraw/rewards). Deployed via `deployCode`.
interface IStakingRewardsFull is IStakingRewardsMinimal {
    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function earned(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function rewardRate() external view returns (uint256);

    function rewardsDuration() external view returns (uint256);

    function setRewardsDistribution(address _rewardsDistribution) external;

    function setRewardsDuration(uint256 _rewardsDuration) external;
}

contract TreasuryVaultTest is Test {
    // Mirrors of the vault's events (0.8.19 cannot reference them as TreasuryVault.X in emit).
    event Distributed(uint256 accrued, uint256 stakerShare, uint256 opsShare, uint256 pushedToStaking);

    uint256 internal constant STAKER_SHARE_BPS = 5_000; // 50%
    uint256 internal constant DISTRIBUTION_EPOCH = 30 days;

    address internal founders = makeAddr("founders");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal randomCaller = makeAddr("randomCaller");

    MockUSDC internal usdc;
    LOOP internal loop;
    IStakingRewardsFull internal staking;
    TreasuryVault internal vault;

    function setUp() public {
        usdc = new MockUSDC();

        // 700M "community supply" parked on a dead address — these tests only need founder LOOP
        // for staking balances.
        loop = new LOOP(makeAddr("distributor"), founders);

        // The real vendored 0.5.16 Synthetix contract, deployed from its artifact.
        staking = IStakingRewardsFull(
            deployCode(
                "src/staking/StakingRewards.sol:StakingRewards",
                abi.encode(address(this), address(this), address(usdc), address(loop))
            )
        );

        vault = new TreasuryVault(
            usdc,
            IStakingRewardsMinimal(address(staking)),
            address(this),
            STAKER_SHARE_BPS,
            DISTRIBUTION_EPOCH
        );

        // Wire the vault as the only allowed reward notifier (StakingRewards owner action).
        staking.setRewardsDistribution(address(vault));

        // Give the stakers LOOP.
        vm.startPrank(founders);
        loop.transfer(alice, 3_000e18);
        loop.transfer(bob, 1_000e18);
        vm.stopPrank();

        // The first distribution epoch is measured from deployment — start the tests past it.
        vm.warp(block.timestamp + DISTRIBUTION_EPOCH);
    }

    /* HELPERS */

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        loop.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @dev Simulates fee revenue having been redeemed into the vault.
    function _fundVault(uint256 amount) internal {
        usdc.mint(address(vault), amount);
    }

    /* THE RETIRED FEE-TOKEN PATH FAILS CLOSED */

    /// @dev The Exchange's fill-time fee path is retired: every order signs
    /// `feeRateBps = 0`, and the ERC-1155 receiver hooks went with it. The Exchange charges
    /// the fee in the asset the taker receives — an outcome token for a BUY order, the only
    /// fee-bearing shape LoopBet ever signed — so such a fill now REVERTS here instead of
    /// stranding tokens the vault could no longer redeem. Re-enabling a fee means a redeploy.
    function testRejectsErc1155Transfers() public {
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature(
                "onERC1155Received(address,address,uint256,uint256,bytes)", address(this), address(this), 1, 1, ""
            )
        );
        assertFalse(ok);
    }

    /// @dev Revenue intake is a plain transfer, whatever the source: the LP commission
    /// and `BettingBankroll.withdrawToTreasury` both arrive this way and both distribute.
    function testPlainTransfersAreTheOnlyIntake() public {
        _fundVault(300e6);
        vault.distribute();

        assertEq(vault.opsBucket(), 150e6);
        assertEq(vault.stakerBucket(), 150e6);
    }

    /* DISTRIBUTE */

    function testDistributeSplitsAndPushesToStakers() public {
        _stake(alice, 1_000e18);
        _fundVault(1_000e6);

        vm.expectEmit(address(vault));
        emit Distributed(1_000e6, 500e6, 500e6, 500e6);

        vm.prank(randomCaller);
        vault.distribute();

        assertEq(usdc.balanceOf(address(staking)), 500e6);
        assertEq(vault.opsBucket(), 500e6);
        assertEq(vault.stakerBucket(), 0);
        assertGt(staking.rewardRate(), 0);
    }

    function testDistributeIsRateLimited() public {
        _stake(alice, 1_000e18);
        _fundVault(1_000e6);
        vault.distribute();

        _fundVault(1_000e6);
        vm.expectRevert(bytes("TreasuryVault: epoch not elapsed"));
        vault.distribute();

        vm.warp(block.timestamp + DISTRIBUTION_EPOCH);
        vault.distribute();

        assertEq(usdc.balanceOf(address(staking)), 1_000e6);
    }

    function testDistributeRollsForwardWhenNobodyStaked() public {
        _fundVault(1_000e6);

        vault.distribute();

        // Nothing pushed, nothing leaked: the staker share waits in the bucket.
        assertEq(vault.opsBucket(), 500e6);
        assertEq(vault.stakerBucket(), 500e6);
        assertEq(usdc.balanceOf(address(staking)), 0);

        // Once someone stakes, a later distribute pushes the pending bucket even with no new revenue.
        _stake(alice, 1_000e18);
        vm.warp(block.timestamp + DISTRIBUTION_EPOCH);
        vault.distribute();

        assertEq(vault.stakerBucket(), 0);
        assertEq(vault.opsBucket(), 500e6);
        assertEq(usdc.balanceOf(address(staking)), 500e6);
    }

    function testDistributeRevertsWhenNothingToDo() public {
        vm.expectRevert(bytes("TreasuryVault: nothing to distribute"));
        vault.distribute();
    }

    function testDistributeSplitRespectsBps(uint256 bps, uint256 revenue) public {
        bps = bound(bps, 0, 10_000);
        revenue = bound(revenue, 1e6, 10_000_000e6);

        vault.setStakerShareBps(bps);
        _stake(alice, 1_000e18);
        _fundVault(revenue);

        vault.distribute();

        uint256 expectedStaker = (revenue * bps) / 10_000;
        assertEq(usdc.balanceOf(address(staking)), expectedStaker);
        assertEq(vault.opsBucket(), revenue - expectedStaker);
    }

    /* OPS BUCKET */

    function testOpsWithdrawBoundedByBucketNotBalance() public {
        // 1000 revenue, nobody staked: ops 500, staker 500 — but the vault *balance* is 1000.
        _fundVault(1_000e6);
        vault.distribute();

        vault.opsWithdraw(alice, 500e6);
        assertEq(usdc.balanceOf(alice), 500e6);

        // The staker bucket is unreachable even though the USDC sits in the vault.
        vm.expectRevert(bytes("TreasuryVault: exceeds ops bucket"));
        vault.opsWithdraw(alice, 1);
    }

    function testOpsWithdrawOnlyOwner() public {
        vm.prank(randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vault.opsWithdraw(randomCaller, 1);
    }

    /* PARAMETERS */

    function testSettersOnlyOwnerAndValidated() public {
        vm.startPrank(randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vault.setStakerShareBps(1);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vault.setDistributionEpoch(1);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vault.setStakingRewards(IStakingRewardsMinimal(address(1)));
        vm.stopPrank();

        vm.expectRevert(bytes("TreasuryVault: bps above 10000"));
        vault.setStakerShareBps(10_001);
        vm.expectRevert(bytes("TreasuryVault: epoch is zero"));
        vault.setDistributionEpoch(0);
        vm.expectRevert(bytes("TreasuryVault: staking is zero"));
        vault.setStakingRewards(IStakingRewardsMinimal(address(0)));

        vault.setStakerShareBps(7_500);
        assertEq(vault.stakerShareBps(), 7_500);
        vault.setDistributionEpoch(7 days);
        assertEq(vault.distributionEpoch(), 7 days);
    }

    /* TIMELOCK INTEGRATION */

    function testOpsWithdrawThroughTimelock() public {
        address multisig = makeAddr("opsMultisig");
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        TimelockController timelock = new TimelockController(48 hours, proposers, executors, address(0));
        vault.transferOwnership(address(timelock));

        _fundVault(1_000e6);
        vault.distribute();

        bytes memory call = abi.encodeCall(vault.opsWithdraw, (multisig, 400e6));

        vm.prank(multisig);
        timelock.schedule(address(vault), 0, call, bytes32(0), bytes32(0), 48 hours);

        // Executing before the public delay fails.
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(vault), 0, call, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        timelock.execute(address(vault), 0, call, bytes32(0), bytes32(0));

        assertEq(usdc.balanceOf(multisig), 400e6);
    }

    /* FULL LOOP: REVENUE → DISTRIBUTE → STAKE REWARDS (real Synthetix contract) */

    function testStakersEarnUsdcProRata() public {
        _stake(alice, 3_000e18);
        _stake(bob, 1_000e18);

        _fundVault(400e6);
        vault.distribute();

        // Let the full reward period elapse (vendored default: 7 days).
        vm.warp(block.timestamp + staking.rewardsDuration());

        vm.prank(alice);
        staking.getReward();
        vm.prank(bob);
        staking.getReward();

        // Stakers receive 50% of the 400 revenue (stakerShareBps), split 3:1 — allowing for
        // rewardRate integer truncation.
        assertApproxEqAbs(usdc.balanceOf(alice), 150e6, 1e6);
        assertApproxEqAbs(usdc.balanceOf(bob), 50e6, 1e6);
        assertGt(usdc.balanceOf(alice), usdc.balanceOf(bob));
    }
}
