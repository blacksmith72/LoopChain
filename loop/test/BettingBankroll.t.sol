// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../lib/forge-std/src/Test.sol";

import {TimelockController} from "../lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {BettingBankroll} from "../src/BettingBankroll.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {ICTFExchange} from "../src/interfaces/ICTFExchange.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";
import {IStakingRewardsMinimal} from "../src/interfaces/IStakingRewardsMinimal.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockExchange} from "./mocks/MockExchange.sol";

/// @dev Staking stand-in. `totalSupply` is settable so the treasury-integration test can
/// exercise both the "nobody staked, roll forward" and "push to stakers" branches.
contract MockStaking is IStakingRewardsMinimal {
    uint256 public totalSupply;
    uint256 public notified;

    function setTotalSupply(uint256 amount) external {
        totalSupply = amount;
    }

    function notifyRewardAmount(uint256 reward) external {
        notified += reward;
    }
}

/// @dev The BettingBankroll: the house's betting capital in its own contract.
///
/// The suite is deliberately short, because the contract is. There is no accounting to test —
/// spend is the balance going down and wins are the balance going up — so what is left is
/// exactly the part that must not regress: the ERC-1271 scoping, the BUY-only property, the
/// fixed-destination exit, and the seam with the treasury (profit only reaches stakers when
/// management moves it).
contract BettingBankrollTest is Test {
    uint256 internal constant STAKER_SHARE_BPS = 5_000; // 50%
    uint256 internal constant DISTRIBUTION_EPOCH = 30 days;

    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    event Redeemed(bytes32 indexed conditionId, uint256 usdcRedeemed);
    event WithdrawnToTreasury(address indexed treasury, uint256 amount);

    address internal makerSigner;
    uint256 internal makerPK;
    address internal guardian = makeAddr("guardian");
    address internal randomCaller = makeAddr("randomCaller");

    MockUSDC internal usdc;
    MockConditionalTokens internal ctf;
    MockStaking internal staking;
    MockExchange internal exchange;
    TreasuryVault internal vault;
    BettingBankroll internal bankroll;

    function setUp() public {
        (makerSigner, makerPK) = makeAddrAndKey("makerSigner");

        usdc = new MockUSDC();
        ctf = new MockConditionalTokens();
        staking = new MockStaking();
        exchange = new MockExchange(usdc);

        vault = new TreasuryVault(
            usdc, IStakingRewardsMinimal(address(staking)), address(this), STAKER_SHARE_BPS, DISTRIBUTION_EPOCH
        );
        bankroll = new BettingBankroll(
            usdc, IConditionalTokens(address(ctf)), address(vault), address(this)
        );

        bankroll.setExchange(ICTFExchange(address(exchange)));
        bankroll.setMakerSigner(makerSigner);
        bankroll.setGuardian(guardian);

        // The vault's first distribution epoch is measured from deployment.
        vm.warp(block.timestamp + DISTRIBUTION_EPOCH);
    }

    /* HELPERS */

    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Funding: a plain USDC transfer. There is no intake function, by design.
    function _fund(uint256 amount) internal {
        usdc.mint(address(bankroll), amount);
    }

    /// @dev A fill spending bankroll capital: the Exchange pulls USDC via the allowance.
    function _bet(uint256 amount) internal {
        exchange.pull(address(bankroll), amount);
    }

    /// @dev Resolves `conditionId` paying the bankroll `amount`, realized via redeem.
    function _redeemPayout(bytes32 conditionId, uint256 amount) internal returns (uint256) {
        usdc.mint(address(ctf), amount);
        ctf.setPayout(conditionId, amount);
        return bankroll.redeem(conditionId);
    }

    /* ERC-1271 */

    function testIsValidSignatureAcceptsMakerKeyFromExchange(bytes32 orderHash) public {
        // The real fork staticcalls isValidSignature from the exchange itself.
        assertEq(exchange.checkSignature(address(bankroll), orderHash, _sign(makerPK, orderHash)), MAGIC);
    }

    function testIsValidSignatureRejectsNonExchangeCaller(bytes32 orderHash) public {
        // The drain guard, and the reason an unlimited allowance is survivable: USDC itself
        // accepts ERC-1271 signatures (permit / transferWithAuthorization), so a maker-key
        // signature must be worthless to every caller except the Exchange — even a valid one.
        bytes memory sig = _sign(makerPK, orderHash);
        assertEq(bankroll.isValidSignature(orderHash, sig), INVALID);

        vm.prank(randomCaller);
        assertEq(bankroll.isValidSignature(orderHash, sig), INVALID);

        vm.prank(address(usdc));
        assertEq(bankroll.isValidSignature(orderHash, sig), INVALID);
    }

    function testIsValidSignatureRejectsWrongKey(bytes32 orderHash) public {
        (, uint256 bobPK) = makeAddrAndKey("bob");
        assertEq(exchange.checkSignature(address(bankroll), orderHash, _sign(bobPK, orderHash)), INVALID);
    }

    function testIsValidSignatureRejectsWhenSignerUnset(bytes32 orderHash) public {
        bankroll.setMakerSigner(address(0));
        // A signature recovering to address(0) must not match an unset (zero) signer.
        assertEq(exchange.checkSignature(address(bankroll), orderHash, _sign(makerPK, orderHash)), INVALID);
    }

    function testIsValidSignatureMalformedSignatureDoesNotRevert() public {
        assertEq(exchange.checkSignature(address(bankroll), bytes32(uint256(1)), hex"deadbeef"), INVALID);
    }

    function testIsValidSignatureRejectsBeforeWiring(bytes32 orderHash) public {
        BettingBankroll fresh =
            new BettingBankroll(usdc, IConditionalTokens(address(ctf)), address(vault), address(this));
        assertEq(fresh.isValidSignature(orderHash, _sign(makerPK, orderHash)), INVALID);
    }

    /* WIRING */

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(bytes("BettingBankroll: usdc is zero"));
        new BettingBankroll(MockUSDC(address(0)), IConditionalTokens(address(ctf)), address(vault), address(this));

        vm.expectRevert(bytes("BettingBankroll: ctf is zero"));
        new BettingBankroll(usdc, IConditionalTokens(address(0)), address(vault), address(this));

        vm.expectRevert(bytes("BettingBankroll: treasury is zero"));
        new BettingBankroll(usdc, IConditionalTokens(address(ctf)), address(0), address(this));

        vm.expectRevert(bytes("BettingBankroll: owner is zero"));
        new BettingBankroll(usdc, IConditionalTokens(address(ctf)), address(vault), address(0));
    }

    function testSettersOnlyOwner() public {
        vm.startPrank(randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        bankroll.setExchange(ICTFExchange(address(exchange)));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        bankroll.setMakerSigner(randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        bankroll.setGuardian(randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        bankroll.setTreasury(randomCaller);
        vm.stopPrank();

        vm.expectRevert(bytes("BettingBankroll: exchange is zero"));
        bankroll.setExchange(ICTFExchange(address(0)));
        vm.expectRevert(bytes("BettingBankroll: treasury is zero"));
        bankroll.setTreasury(address(0));
    }

    function testSetExchangeGrantsUnlimitedAllowanceAndRevokesTheOld() public {
        assertEq(usdc.allowance(address(bankroll), address(exchange)), type(uint256).max);

        MockExchange exchange2 = new MockExchange(usdc);
        bankroll.setExchange(ICTFExchange(address(exchange2)));

        assertEq(usdc.allowance(address(bankroll), address(exchange)), 0);
        assertEq(usdc.allowance(address(bankroll), address(exchange2)), type(uint256).max);
    }

    /// @dev BUY-only by construction: the Exchange is never granted a CTF operator approval, so
    /// a SELL fill reverts at the token pull and the maker key cannot give positions away.
    /// The bankroll has no function that could grant one — this asserts it stays that way.
    function testNeverApprovesTheExchangeForOutcomeTokens() public {
        _fund(100e6);
        _bet(40e6);
        _redeemPayout(bytes32(uint256(1)), 90e6);

        assertFalse(ctf.isApprovedForAll(address(bankroll), address(exchange)));
    }

    /* RISK-OFF PASSTHROUGHS */

    function _bankrollOrder() internal view returns (ICTFExchange.Order[] memory orders) {
        orders = new ICTFExchange.Order[](1);
        orders[0].maker = address(bankroll);
        orders[0].signer = address(bankroll);
        orders[0].signatureType = 3; // POLY_1271
    }

    function testCancelOrdersAuthAndForwarding() public {
        vm.prank(randomCaller);
        vm.expectRevert(bytes("BettingBankroll: not maker or guardian"));
        bankroll.cancelOrders(_bankrollOrder());
        vm.expectRevert(bytes("BettingBankroll: not maker or guardian"));
        bankroll.cancelOrders(_bankrollOrder()); // the owner has no fast path either

        vm.prank(makerSigner);
        bankroll.cancelOrders(_bankrollOrder());
        vm.prank(guardian);
        bankroll.cancelOrders(_bankrollOrder());
        assertEq(exchange.cancelledCount(), 2);
    }

    function testIncrementNonceAuthAndForwarding() public {
        vm.prank(randomCaller);
        vm.expectRevert(bytes("BettingBankroll: not maker or guardian"));
        bankroll.incrementNonce();

        vm.prank(makerSigner);
        bankroll.incrementNonce();
        assertEq(exchange.nonces(address(bankroll)), 1);
    }

    /* REDEEM */

    function testRedeemIsPermissionlessAndProceedsJustLand(bytes32 conditionId, uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        usdc.mint(address(ctf), amount);
        ctf.setPayout(conditionId, amount);

        vm.expectEmit(address(bankroll));
        emit Redeemed(conditionId, amount);

        vm.prank(randomCaller);
        uint256 redeemed = bankroll.redeem(conditionId);

        assertEq(redeemed, amount);
        assertEq(usdc.balanceOf(address(bankroll)), amount);
    }

    /* THE EXIT */

    function testWithdrawToTreasuryPaysOnlyTheTreasury() public {
        _fund(100e6);

        vm.expectEmit(address(bankroll));
        emit WithdrawnToTreasury(address(vault), 40e6);

        vm.prank(guardian);
        bankroll.withdrawToTreasury(40e6);

        assertEq(usdc.balanceOf(address(vault)), 40e6);
        assertEq(usdc.balanceOf(address(bankroll)), 60e6);
    }

    function testWithdrawToTreasuryAuth() public {
        _fund(100e6);

        vm.prank(randomCaller);
        vm.expectRevert(bytes("BettingBankroll: not guardian or owner"));
        bankroll.withdrawToTreasury(1);

        vm.prank(makerSigner);
        vm.expectRevert(bytes("BettingBankroll: not guardian or owner"));
        bankroll.withdrawToTreasury(1);

        // The owner (= the Timelock) can also do it, e.g. inside a governance batch.
        bankroll.withdrawToTreasury(1);
        assertEq(usdc.balanceOf(address(vault)), 1);

        vm.prank(guardian);
        vm.expectRevert(bytes("BettingBankroll: amount is zero"));
        bankroll.withdrawToTreasury(0);
    }

    function testWithdrawToTreasuryFollowsARetargetedTreasury() public {
        TreasuryVault vault2 = new TreasuryVault(
            usdc, IStakingRewardsMinimal(address(staking)), address(this), STAKER_SHARE_BPS, DISTRIBUTION_EPOCH
        );
        bankroll.setTreasury(address(vault2));

        _fund(50e6);
        vm.prank(guardian);
        bankroll.withdrawToTreasury(50e6);

        assertEq(usdc.balanceOf(address(vault2)), 50e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /* THE OPERATING LOOP */

    /// @dev The whole point of the split: a full bet cycle with no governance action anywhere,
    /// no allowance re-arm, and no accounting call. Spend is the balance down, wins are the
    /// balance up, and the profit is simply the difference.
    function testFullBettingCycleNeedsNoGovernanceAction() public {
        _fund(100e6);

        _bet(100e6);
        assertEq(usdc.balanceOf(address(bankroll)), 0);

        _redeemPayout(bytes32(uint256(7)), 160e6);
        assertEq(usdc.balanceOf(address(bankroll)), 160e6);

        // A losing round is just a smaller balance — nothing to write off.
        _bet(60e6);
        assertEq(usdc.balanceOf(address(bankroll)), 100e6);

        // And the bankroll heals itself: the next win lands without anyone re-arming anything.
        _redeemPayout(bytes32(uint256(8)), 90e6);
        assertEq(usdc.balanceOf(address(bankroll)), 190e6);
    }

    /* THE TREASURY SEAM */

    /// @dev Betting profit belongs to stakers, but it compounds in the bankroll until
    /// management moves it: `withdrawToTreasury` makes it ordinary revenue, and the next
    /// `distribute()` splits it. Until then no distribution can see it.
    function testProfitReachesStakersOnlyWhenManagementMovesIt() public {
        staking.setTotalSupply(1_000e18);

        // Treasury funds the bankroll out of the ops bucket (a timelocked owner call in
        // production; this test owns the vault directly).
        usdc.mint(address(vault), 200e6);
        vault.distribute();
        assertEq(vault.opsBucket(), 100e6);
        vault.opsWithdraw(address(bankroll), 100e6);

        // The house wins: 100 staked becomes 180.
        _bet(100e6);
        _redeemPayout(bytes32(uint256(11)), 180e6);
        assertEq(usdc.balanceOf(address(bankroll)), 180e6);

        // Profit is invisible to the treasury until it is moved.
        vm.warp(block.timestamp + DISTRIBUTION_EPOCH);
        vm.expectRevert(bytes("TreasuryVault: nothing to distribute"));
        vault.distribute();

        // Management sweeps the 80 profit back, keeping the 100 bankroll working.
        vm.prank(guardian);
        bankroll.withdrawToTreasury(80e6);
        assertEq(usdc.balanceOf(address(bankroll)), 100e6);

        uint256 notifiedBefore = staking.notified();
        vault.distribute();

        // It split like any other revenue: 50% pushed to stakers, 50% to ops.
        assertEq(staking.notified() - notifiedBefore, 40e6);
        assertEq(vault.opsBucket(), 40e6);
    }

    /// @dev The containment property the split exists for: betting can never touch USDC
    /// backing the ops or staker buckets, because it is in another contract entirely.
    function testBettingCannotReachTreasuryMoney() public {
        usdc.mint(address(vault), 1_000e6);
        vault.distribute();

        _fund(10e6);
        _bet(10e6);

        // The Exchange has no claim on the vault at all — not a capped one, none.
        assertEq(usdc.allowance(address(vault), address(exchange)), 0);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
        assertEq(vault.opsBucket() + vault.stakerBucket(), 1_000e6);
    }

    /* CONSERVATION (FUZZ) */

    function testFuzzBalanceIsTheOnlyAccounting(uint256 funded, uint256 spend, uint256 payout) public {
        funded = bound(funded, 0, 1_000_000e6);
        spend = bound(spend, 0, funded);
        payout = bound(payout, 0, 2_000_000e6);

        _fund(funded);
        _bet(spend);
        _redeemPayout(bytes32(uint256(42)), payout);

        // No odometer, no float, no outstanding: the bankroll IS the balance.
        assertEq(usdc.balanceOf(address(bankroll)), funded - spend + payout);

        uint256 held = usdc.balanceOf(address(bankroll));
        if (held > 0) {
            vm.prank(guardian);
            bankroll.withdrawToTreasury(held);
            assertEq(usdc.balanceOf(address(bankroll)), 0);
            assertEq(usdc.balanceOf(address(vault)), held);
        }
    }

    /* TIMELOCK INTEGRATION */

    /// @dev Wiring is timelocked (announced before it lands); the risk-off and treasury-sweep
    /// paths deliberately are not.
    function testWiringGoesThroughTheTimelockButRiskOffDoesNot() public {
        address multisig = makeAddr("opsMultisig");
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        TimelockController timelock = new TimelockController(48 hours, proposers, executors, address(0));
        bankroll.setGuardian(multisig);
        bankroll.transferOwnership(address(timelock));

        address newSigner = makeAddr("rotatedMakerKey");
        bytes memory call = abi.encodeCall(bankroll.setMakerSigner, (newSigner));

        vm.prank(multisig);
        timelock.schedule(address(bankroll), 0, call, bytes32(0), bytes32(0), 48 hours);

        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(bankroll), 0, call, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        timelock.execute(address(bankroll), 0, call, bytes32(0), bytes32(0));
        assertEq(bankroll.makerSigner(), newSigner);

        // Meanwhile the guardian kills exposure and sweeps the bankroll home with no delay.
        _fund(25e6);
        vm.startPrank(multisig);
        bankroll.incrementNonce();
        bankroll.withdrawToTreasury(25e6);
        vm.stopPrank();

        assertEq(exchange.nonces(address(bankroll)), 1);
        assertEq(usdc.balanceOf(address(vault)), 25e6);
    }
}
