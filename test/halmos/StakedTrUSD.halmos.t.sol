// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TrUSD } from "../../contracts/core/TrUSD.sol";
import { StakedTrUSD } from "../../contracts/core/StakedTrUSD.sol";
import { UserCooldown } from "../../contracts/interfaces/IStakedTrUSDCooldown.sol";
import { HalmosBase } from "./HalmosBase.sol";

/// @notice Shared deployment: trUSD and strUSD behind their ERC1967 proxies, wired as in production.
abstract contract StakedTrUSDFixture is HalmosBase {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 internal constant BLACKLIST_MANAGER_ROLE = keccak256("BLACKLIST_MANAGER_ROLE");
    bytes32 internal constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");
    bytes32 internal constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    uint256 internal constant VESTING_PERIOD = 8 hours;
    uint256 internal constant MIN_SHARES = 1 ether;
    uint256 internal constant MAX_COOLDOWN = 90 days;

    TrUSD internal trUSD;
    StakedTrUSD internal vault;

    address internal admin = address(0xA11CE);
    address internal timelock = address(0x71E10C);
    address internal rewarder = address(0x5EED);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    function _deploy() internal {
        TrUSD tImpl = new TrUSD();
        trUSD = TrUSD(address(new ERC1967Proxy(address(tImpl), abi.encodeCall(TrUSD.initialize, (admin)))));
        vm.prank(admin);
        trUSD.initializeTimelockAdmin(timelock);
        // The test contract is the trUSD minter, so a property can fund any account.
        vm.prank(timelock);
        trUSD.setMinter(address(this));

        StakedTrUSD sImpl = new StakedTrUSD();
        vault = StakedTrUSD(
            address(
                new ERC1967Proxy(
                    address(sImpl), abi.encodeCall(StakedTrUSD.initialize, (address(trUSD), rewarder, admin))
                )
            )
        );
        vm.prank(admin);
        vault.initializeTimelockAdmin(timelock);

        vm.prank(rewarder);
        trUSD.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        trUSD.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        trUSD.approve(address(vault), type(uint256).max);
    }

    /// @dev Approves for `who` itself: a property that stakes for a symbolic caller must not lose the
    ///      callers that never approved (their paths would revert in setup and be silently dropped).
    function _stake(address who, uint256 assets) internal returns (uint256 shares) {
        trUSD.mint(who, assets);
        vm.prank(who);
        trUSD.approve(address(vault), type(uint256).max);
        vm.prank(who);
        shares = vault.deposit(assets, who);
    }

    function _reward(uint256 amount) internal {
        trUSD.mint(rewarder, amount);
        vm.prank(rewarder);
        vault.transferInRewards(amount);
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT))));
    }
}

/// @title StakedTrUSDHalmos
/// @notice Symbolic properties of the strUSD ERC4626 vault: cooldown, blacklist and access control.
///         The share/asset arithmetic is in StakedTrUSDMathHalmos.
contract StakedTrUSDHalmos is StakedTrUSDFixture {
    function setUp() public {
        _deploy();
    }

    /* ---------------- rewards and losses ---------------- */

    /// @notice Only the rewarder can send rewards or report a loss.
    function check_rewardAndLoss_onlyRewarder(address caller, uint256 amount, bool isLoss) public {
        vm.assume(caller != rewarder);
        _stake(alice, 10 ether);
        trUSD.mint(caller, amount);
        vm.prank(caller);
        trUSD.approve(address(vault), type(uint256).max);

        vm.prank(caller);
        (bool ok,) = isLoss
            ? address(vault).call(abi.encodeCall(vault.reportLoss, (amount)))
            : address(vault).call(abi.encodeCall(vault.transferInRewards, (amount)));
        assert(!ok);
    }

    /* ---------------- cooldown ---------------- */

    /// @notice No call by anyone, the admin included, can set a cooldown above 90 days, and no cooldown
    ///         can end later than 90 days from now.
    /// @dev The timelock is excluded: its upgrade right can by design replace the logic.
    function check_cooldown_boundedBy90Days(address caller) public {
        vm.assume(caller != timelock);
        // Give the caller shares when it can hold them; never revert here, or that caller's paths
        // would be dropped from the property.
        _stake(alice, 10 ether);
        trUSD.mint(alice, 10 ether);
        vm.prank(alice);
        (bool funded,) = address(trUSD).call(abi.encodeCall(trUSD.transfer, (caller, 10 ether)));
        vm.prank(caller);
        (funded,) = address(trUSD).call(abi.encodeCall(trUSD.approve, (address(vault), type(uint256).max)));
        vm.prank(caller);
        (funded,) = address(vault).call(abi.encodeCall(vault.deposit, (10 ether, caller)));
        funded;
        _arbitraryCall(address(vault), "StakedTrUSD", caller);
        assert(vault.cooldownDuration() <= MAX_COOLDOWN);
        assert(vault.cooldowns(caller).cooldownEnd <= block.timestamp + MAX_COOLDOWN);
    }

    /// @notice setCooldownDuration rejects anything above 90 days, even from the admin.
    function check_setCooldownDuration_rejectsAbove90Days(uint24 duration) public {
        vm.assume(duration > MAX_COOLDOWN);
        vm.prank(admin);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.setCooldownDuration, (duration)));
        assert(!ok);
    }

    /// @notice While a cooldown is configured, ERC4626 withdraw and redeem are closed to everyone.
    function check_withdrawRedeem_closedWhileCooldownOn(address caller, uint256 amount, bool useRedeem) public {
        _stake(alice, 10 ether);
        vm.prank(caller);
        (bool ok,) = useRedeem
            ? address(vault).call(abi.encodeCall(vault.redeem, (amount, caller, alice)))
            : address(vault).call(abi.encodeCall(vault.withdraw, (amount, caller, alice)));
        assert(!ok);
    }

    /// @notice unstake before the cooldown ends always reverts.
    function check_unstake_notBeforeCooldownEnd(uint256 shares, uint256 early) public {
        uint256 staked = _stake(bob, 10 ether);
        vm.assume(shares > 0 && shares <= staked);
        vm.prank(bob);
        vault.cooldownShares(shares);
        uint256 end = vault.cooldowns(bob).cooldownEnd;
        vm.assume(early < end && early >= block.timestamp);
        vm.warp(early);

        vm.prank(bob);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.unstake, (bob)));
        assert(!ok);
    }

    /* ---------------- blacklist ---------------- */

    /// @notice A blacklisted holder's shares and cooldown can be moved by nobody except the admin
    ///         (redistributeLockedAmount / seizeCooldown) and the timelock (upgrade).
    function check_blacklisted_sharesAndCooldownFrozen(address caller) public {
        vm.assume(caller != admin && caller != timelock);
        _stake(alice, 10 ether);
        _stake(bob, 10 ether);
        vm.prank(bob);
        vault.cooldownShares(1 ether);
        vm.prank(admin);
        vault.addToBlacklist(bob);

        uint256 shares = vault.balanceOf(bob);
        uint256 cooling = vault.cooldowns(bob).underlyingAmount;

        _arbitraryCall(address(vault), "StakedTrUSD", caller);

        assert(vault.balanceOf(bob) == shares);
        assert(vault.cooldowns(bob).underlyingAmount == cooling);
    }

    /// @notice No share transfer can involve a blacklisted address on either side.
    function check_blacklisted_cannotSendOrReceive(address other, uint256 amount, bool outbound) public {
        _stake(alice, 10 ether);
        _stake(bob, 10 ether);
        vm.prank(admin);
        vault.addToBlacklist(bob);

        address from = outbound ? bob : alice;
        address to = outbound ? other : bob;
        vm.prank(from);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.transfer, (to, amount)));
        assert(!ok);
    }

    /// @notice Nobody but the owner itself can blacklist the owner (default admin).
    /// @dev Narrowed after halmos found that the owner CAN blacklist itself: DEFAULT_ADMIN_ROLE is the
    ///      admin of FULL_RESTRICTED_STAKER_ROLE, so `grantRole(FULL_RESTRICTED_STAKER_ROLE, owner())`
    ///      bypasses the `notOwner` guard on addToBlacklist. See test/halmos/README.md, finding F-1.
    ///      The timelock is excluded: its upgrade right can by design replace the logic.
    function check_owner_neverBlacklistedByOthers(address caller) public {
        vm.assume(caller != admin && caller != timelock);
        _arbitraryCall(address(vault), "StakedTrUSD", caller);
        assert(!vault.hasRole(FULL_RESTRICTED_STAKER_ROLE, vault.owner()));
    }

    /* ---------------- access control ---------------- */

    /// @notice A caller holding no role cannot change roles, vesting, cooldown config or the
    ///         implementation, by any call.
    function check_privilegedState_onlyRoleHolders(address caller, address who) public {
        vm.assume(caller != admin && caller != timelock && caller != rewarder);
        _stake(alice, 10 ether);

        uint256 rolesBefore = _roleMask(who);
        uint256 vesting = vault.vestingAmount();
        uint256 lastDist = vault.lastDistributionTimestamp();
        uint24 cd = vault.cooldownDuration();
        address impl = _implementation();

        _arbitraryCall(address(vault), "StakedTrUSD", caller);

        assert(_roleMask(who) == rolesBefore);
        assert(vault.vestingAmount() == vesting);
        assert(vault.lastDistributionTimestamp() == lastDist);
        assert(vault.cooldownDuration() == cd);
        assert(_implementation() == impl);
    }

    /// @notice Upgrading to a genuine new implementation reverts for every caller but the timelock.
    function check_upgradeToAndCall_onlyTimelock(address caller) public {
        vm.assume(caller != timelock);
        StakedTrUSD next = new StakedTrUSD();
        vm.prank(caller);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.upgradeToAndCall, (address(next), "")));
        assert(!ok);
    }

    /// @notice The admin cannot grant, revoke or re-seat TIMELOCK_ADMIN_ROLE, nor upgrade.
    function check_admin_cannotTouchTimelockRoleOrUpgrade(address who) public {
        bool before = vault.hasRole(TIMELOCK_ADMIN_ROLE, who);
        address impl = _implementation();
        _arbitraryCall(address(vault), "StakedTrUSD", admin);
        assert(vault.hasRole(TIMELOCK_ADMIN_ROLE, who) == before);
        assert(_implementation() == impl);
    }

    /// @notice Total share supply is always zero or at least MIN_SHARES after any call.
    function check_minShares_preserved(address caller) public {
        vm.assume(caller != timelock);
        _stake(alice, MIN_SHARES);
        _arbitraryCall(address(vault), "StakedTrUSD", caller);
        uint256 supply = vault.totalSupply();
        assert(supply == 0 || supply >= MIN_SHARES);
    }

    /// @notice The vault's own asset can never be pulled out through rescueTokens.
    function check_rescueTokens_cannotTakeAsset(address to, uint256 amount) public {
        _stake(alice, 10 ether);
        vm.prank(admin);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.rescueTokens, (address(trUSD), amount, to)));
        assert(!ok);
    }

    /// @notice rescueOrphanFunds is unreachable while any shares exist.
    function check_rescueOrphanFunds_onlyWithNoShares(address to) public {
        _stake(alice, MIN_SHARES);
        vm.prank(admin);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.rescueOrphanFunds, (to)));
        assert(!ok);
    }

    /// @dev Bit set per role `who` holds: admin, rewarder, blacklist manager, blacklisted, timelock.
    function _roleMask(address who) internal view returns (uint256) {
        return _bit(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), who)) | _bit(vault.hasRole(REWARDER_ROLE, who)) << 1
            | _bit(vault.hasRole(BLACKLIST_MANAGER_ROLE, who)) << 2
            | _bit(vault.hasRole(FULL_RESTRICTED_STAKER_ROLE, who)) << 3 | _bit(vault.hasRole(TIMELOCK_ADMIN_ROLE, who))
            << 4;
    }
}

/// @title StakedTrUSDMathHalmos
/// @notice Reward and loss arithmetic of the strUSD vault.
/// @dev Bound, applied to every property here: amounts (stake, reward, loss) are fully symbolic up to
///      2^96 (79bn trUSD). Properties about a loss are checked once the last reward has fully vested
///      (8h, or a day, after it). Inside the window `(VESTING_PERIOD - elapsed) * vestingAmount /
///      VESTING_PERIOD` and the re-solved vesting amount are symbolic multiplies and divides that
///      neither yices nor z3 closes within an hour, even with elapsed concrete. The ERC4626 share/asset rounding properties are not here: every conversion goes
///      through OZ Math.mulDiv, whose 512-bit `mulmod` is intractable for the solver even against a
///      constant operand. See test/halmos/README.md, "Not provable with halmos".
contract StakedTrUSDMathHalmos is StakedTrUSDFixture {
    function setUp() public {
        _deploy();
    }

    /// @dev Time since the reward: the end of the vesting window, or a day later.
    function _elapsed(uint8 e) internal pure returns (uint256) {
        return e == 0 ? VESTING_PERIOD : 1 days;
    }

    /// @notice A reward does not move the share price in the block it lands; it vests linearly.
    function check_transferInRewards_noInstantPriceJump(uint96 seed, uint96 reward) public {
        vm.assume(seed >= MIN_SHARES && reward > 0);
        _stake(alice, seed);
        uint256 before = vault.totalAssets();
        _reward(reward);
        assert(vault.totalAssets() == before);
    }

    /// @notice A reward is fully reflected in totalAssets once the vesting period has passed.
    function check_vesting_completeAfterPeriod(uint96 seed, uint96 reward, uint32 extra) public {
        vm.assume(seed >= MIN_SHARES && reward > 0);
        _stake(alice, seed);
        _reward(reward);
        vm.warp(block.timestamp + VESTING_PERIOD + extra);
        assert(vault.getUnvestedAmount() == 0);
        assert(vault.totalAssets() == uint256(seed) + reward);
    }

    /// @notice With nothing left vesting, a loss lowers totalAssets by exactly what it burnt.
    function check_reportLoss_lowersAssetsByBurnt(uint96 seed, uint96 reward, uint8 e, uint96 loss) public {
        vm.assume(seed >= MIN_SHARES && loss > 0);
        _stake(alice, seed);
        if (reward > 0) _reward(reward);
        vm.warp(block.timestamp + _elapsed(e));

        uint256 before = vault.totalAssets();
        uint256 supplyBefore = trUSD.totalSupply();
        vm.prank(rewarder);
        vault.reportLoss(loss);
        assert(vault.totalAssets() == before - (supplyBefore - trUSD.totalSupply()));
    }

    // ---- 1.1.0 daily loss cap: one report per LOSS_INTERVAL, at most MAX_DAILY_LOSS_BPS of totalAssets ----

    /// @notice A loss report above 5% of totalAssets is refused.
    function check_reportLoss_rejectsAboveCap(uint96 seed, uint96 loss) public {
        vm.assume(seed >= MIN_SHARES);
        _stake(alice, seed);
        vm.assume(uint256(loss) > (vault.totalAssets() * 500) / 10_000);

        vm.prank(rewarder);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.reportLoss, (loss)));
        assert(!ok);
    }

    /// @dev Stake grid for the two cap properties below: the floor, one wei above it, an odd mid amount, an odd
    ///      amount near the top of the 2^96 range. With the stake symbolic, `totalAssets * 500 / 10_000` next to
    ///      the loss arithmetic does not close in the solver within the CI budget; the loss stays symbolic.
    function _stakeGrid(uint8 s) internal pure returns (uint256) {
        if (s == 0) return MIN_SHARES;
        if (s == 1) return MIN_SHARES + 1;
        if (s == 2) return 1_000_000 ether + 7;
        return 79_000_000_000 ether - 3;
    }

    /// @notice An accepted loss report lowers totalAssets by at most 5%.
    function check_reportLoss_lowersAssetsAtMostFivePercent(uint8 s, uint96 loss) public {
        vm.assume(s < 4 && loss > 0);
        _stake(alice, _stakeGrid(s));

        uint256 before = vault.totalAssets();
        vm.prank(rewarder);
        vault.reportLoss(loss);
        assert(vault.totalAssets() * 10_000 >= before * 9_500);
    }

    /// @notice After an accepted loss report, every further report within 24 hours is refused.
    function check_reportLoss_oncePerInterval(uint96 seed, uint96 first, uint96 second, uint32 dt) public {
        vm.assume(seed >= MIN_SHARES && first > 0 && dt < 1 days);
        _stake(alice, seed);

        vm.prank(rewarder);
        vault.reportLoss(first);
        vm.warp(block.timestamp + dt);

        vm.prank(rewarder);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.reportLoss, (second)));
        assert(!ok);
    }

    /// @notice Once 24 hours have passed, a report within the cap is accepted again.
    function check_reportLoss_acceptedAfterInterval(uint8 s, uint32 extra) public {
        vm.assume(s < 4);
        _stake(alice, _stakeGrid(s));

        vm.prank(rewarder);
        vault.reportLoss(1);
        vm.warp(block.timestamp + 1 days + extra);

        vm.prank(rewarder);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.reportLoss, (1)));
        assert(ok);
    }
}
