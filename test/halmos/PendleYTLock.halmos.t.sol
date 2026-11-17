// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PendleYTLock } from "../../contracts/core/PendleYTLock.sol";
import { MockPendleYT } from "../mocks/MockPendleYT.sol";
import { HalmosBase } from "./HalmosBase.sol";

/// @title PendleYTLockHalmos
/// @notice Symbolic properties of the YT lock: principal backing, withdrawal gating, yield reserve
///         backing and access control. Pendle is modelled by test/mocks/MockPendleYT.sol, which
///         reproduces the interest checkpointing PendleYTLock depends on.
/// @dev Bounds: properties whose state involves the share supply or the yield index take the two
///      lockers' deposits from the grid in `_deposits` and the Pendle interest from the grid in
///      `_yield`. The 1e27 index arithmetic `(received * 1e27) / supply` and `balance * delta / 1e27`
///      with a symbolic amount times out in both bundled solvers, even with the supply concrete (see
///      StakedTrUSDMathHalmos for the same limit). Caller, function and every argument of the call
///      under test stay symbolic.
contract PendleYTLockHalmos is HalmosBase {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Deposit grid (alice, bob): equal, dust next to a whole token, awkward and large, off by a wei.
    /// @dev Pendle interest grid: none, one wei, an odd whole amount, a large odd amount.
    function _yield(uint8 j) internal pure returns (uint256) {
        if (j == 0) return 0;
        if (j == 1) return 1;
        if (j == 2) return 1e18 + 7;
        return 3e24 + 1;
    }

    function _deposits(uint8 k) internal returns (uint256 a, uint256 b) {
        vm.assume(k < 4);
        if (k == 0) (a, b) = (1e18, 1e18);
        else if (k == 1) (a, b) = (1, 1e18);
        else if (k == 2) (a, b) = (7e18 + 1, 2e24 + 3);
        else (a, b) = (5e17, 5e17 + 1);
        _lockYT(alice, a);
        _lockYT(bob, b);
    }

    PendleYTLock internal lock;
    MockPendleYT internal yt;
    IERC20 internal sy;

    address internal admin = address(0xA11CE);
    address internal timelock = address(0x71E10C);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    function setUp() public {
        yt = new MockPendleYT();
        sy = IERC20(yt.SY());
        PendleYTLock impl = new PendleYTLock();
        lock = PendleYTLock(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(PendleYTLock.initialize, (address(yt), admin, "Locked YT", "lYT"))
                )
            )
        );
        vm.prank(admin);
        lock.initializeTimelockAdmin(timelock);

        vm.prank(alice);
        yt.approve(address(lock), type(uint256).max);
        vm.prank(bob);
        yt.approve(address(lock), type(uint256).max);
    }

    function _lockYT(address who, uint256 amount) internal returns (uint256 shares) {
        yt.mint(who, amount);
        vm.prank(who);
        shares = lock.deposit(amount, who);
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(lock), IMPLEMENTATION_SLOT))));
    }

    /// @notice While withdrawals are paused (the default) nobody can withdraw or redeem YT.
    function check_withdrawalsPaused_blockExit(address caller, uint256 amount, bool useRedeem) public {
        _lockYT(alice, 10 ether);
        vm.prank(caller);
        (bool ok,) = useRedeem
            ? address(lock).call(abi.encodeCall(lock.redeem, (amount, caller, alice)))
            : address(lock).call(abi.encodeCall(lock.withdraw, (amount, caller, alice)));
        assert(!ok);
    }

    /// @notice Nobody but the timelock can pause withdrawals, and nobody but the timelock or the admin can
    ///         unpause them, by any call.
    /// @dev The timelock itself is not a caller here: its upgrade right can by design replace the logic,
    ///      and the property is about everyone else.
    function check_withdrawalPause_onlyGovernance(address caller, bool startPaused) public {
        vm.assume(caller != timelock);
        if (!startPaused) {
            vm.prank(admin);
            lock.unpauseWithdrawals();
        }
        bool before = lock.withdrawalsPaused();
        _arbitraryCall(address(lock), "PendleYTLock", caller);
        bool afterwards = lock.withdrawalsPaused();

        assert(before || !afterwards);
        if (before && !afterwards) assert(caller == admin);
    }

    /// @notice The locked YT always covers totalAssets, whatever anyone but the timelock does, the
    ///         admin included.
    function check_principal_alwaysBacked(address caller, uint8 k) public {
        vm.assume(caller != timelock);
        _deposits(k);
        vm.prank(admin);
        lock.unpauseWithdrawals();

        _arbitraryCall(address(lock), "PendleYTLock", caller);

        assert(yt.balanceOf(address(lock)) >= lock.totalAssets());
    }

    /// @notice A new deposit between two harvests never dilutes booked yield or unbacks the reserve: the
    ///         depositor is settled at the current index before its shares exist.
    function check_yieldReserve_backedAcrossDeposit(uint8 k, uint8 j1, uint8 d, uint8 j2) public {
        _deposits(k);
        uint256 y1 = _yield(j1);
        uint256 y2 = _yield(j2);
        if (y1 > 0) yt.accrueInterestFor(address(lock), y1);
        lock.claimPendleYield();
        uint256 aliceBefore = lock.claimableYield(alice);

        // New locker from a small grid of sizes, then more interest and another harvest.
        vm.assume(d < 3);
        address carol = address(0xCA201);
        vm.prank(carol);
        yt.approve(address(lock), type(uint256).max);
        _lockYT(carol, d == 0 ? 1 : d == 1 ? 1e18 : 3e24 + 1);
        assert(lock.claimableYield(carol) == 0);
        assert(lock.claimableYield(alice) == aliceBefore);

        if (y2 > 0) yt.accrueInterestFor(address(lock), y2);
        lock.claimPendleYield();

        uint256 reserved = lock.reservedYield();
        assert(sy.balanceOf(address(lock)) >= reserved + lock.orphanedYield());
        assert(lock.claimableYield(alice) + lock.claimableYield(bob) + lock.claimableYield(carol) <= reserved);
    }

    /// @notice A harvest attributes everything it receives except rounding dust, and never more than
    ///         it received.
    function check_harvest_attributesAtMostReceived(uint8 k, uint8 j) public {
        uint256 y = _yield(j);
        vm.assume(y > 0);
        _deposits(k);
        yt.accrueInterestFor(address(lock), y);

        uint256 distributed = lock.claimPendleYield();
        assert(distributed <= y);
        assert(lock.reservedYield() == distributed);
        assert(lock.claimableYield(alice) + lock.claimableYield(bob) <= distributed);
    }

    /// @notice The locked YT and the Pendle SY can never be pulled out with rescueTokens.
    function check_rescueTokens_cannotTakePrincipalOrYield(uint256 amount, address to, bool takeSY) public {
        _lockYT(alice, 10 ether);
        yt.accrueInterestFor(address(lock), 1 ether);
        lock.claimPendleYield();
        vm.prank(admin);
        (bool ok,) =
            address(lock).call(abi.encodeCall(lock.rescueTokens, (takeSY ? address(sy) : address(yt), amount, to)));
        assert(!ok);
    }

    /// @notice A caller holding no role cannot change roles, the emergency pause or the
    ///         implementation, by any call.
    function check_privilegedState_onlyRoleHolders(address caller, address who) public {
        vm.assume(caller != admin && caller != timelock);
        _lockYT(alice, 10 ether);
        bytes32 adminRole = lock.DEFAULT_ADMIN_ROLE();
        bytes32 tlRole = lock.TIMELOCK_ADMIN_ROLE();
        bool ad = lock.hasRole(adminRole, who);
        bool tl = lock.hasRole(tlRole, who);
        bool paused = lock.paused();
        address impl = _implementation();

        _arbitraryCall(address(lock), "PendleYTLock", caller);

        assert(lock.hasRole(adminRole, who) == ad);
        assert(lock.hasRole(tlRole, who) == tl);
        assert(lock.paused() == paused);
        assert(_implementation() == impl);
    }

    /// @notice Upgrading to a genuine new implementation reverts for every caller but the timelock.
    function check_upgradeToAndCall_onlyTimelock(address caller) public {
        vm.assume(caller != timelock);
        PendleYTLock next = new PendleYTLock();
        vm.prank(caller);
        (bool ok,) = address(lock).call(abi.encodeCall(lock.upgradeToAndCall, (address(next), "")));
        assert(!ok);
    }

    /// @notice The admin cannot grant or move TIMELOCK_ADMIN_ROLE, upgrade, or pause withdrawals.
    function check_admin_cannotBypassTimelock(address who) public {
        vm.prank(admin);
        lock.unpauseWithdrawals();
        bytes32 tlRole = lock.TIMELOCK_ADMIN_ROLE();
        bool tl = lock.hasRole(tlRole, who);
        address impl = _implementation();

        _arbitraryCall(address(lock), "PendleYTLock", admin);

        assert(lock.hasRole(tlRole, who) == tl);
        assert(_implementation() == impl);
        assert(!lock.withdrawalsPaused());
    }
}

/// @title PendleYTLockNoYieldHalmos
/// @notice PendleYTLock 4.0.0 in yield-off mode (`initializeWithoutYield`), the mode of a lock whose SY pays
///         nothing (the trUSD lock of 25 Feb 2027).
/// @dev Deposits come from the same four-point grid as PendleYTLockHalmos; caller, function and every
///      argument of the call under test stay symbolic.
contract PendleYTLockNoYieldHalmos is HalmosBase {
    PendleYTLock internal lock;
    MockPendleYT internal yt;

    address internal admin = address(0xA11CE);
    address internal timelock = address(0x71E10C);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    function setUp() public {
        yt = new MockPendleYT();
        PendleYTLock impl = new PendleYTLock();
        lock = PendleYTLock(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(PendleYTLock.initializeWithoutYield, (address(yt), admin, "Locked YT", "lYT"))
                )
            )
        );
        vm.prank(admin);
        lock.initializeTimelockAdmin(timelock);

        vm.prank(alice);
        yt.approve(address(lock), type(uint256).max);
        vm.prank(bob);
        yt.approve(address(lock), type(uint256).max);
    }

    function _deposits(uint8 k) internal {
        vm.assume(k < 4);
        uint256 a;
        uint256 b;
        if (k == 0) (a, b) = (1e18, 1e18);
        else if (k == 1) (a, b) = (1, 1e18);
        else if (k == 2) (a, b) = (7e18 + 1, 2e24 + 3);
        else (a, b) = (5e17, 5e17 + 1);
        yt.mint(alice, a);
        vm.prank(alice);
        lock.deposit(a, alice);
        yt.mint(bob, b);
        vm.prank(bob);
        lock.deposit(b, bob);
    }

    /// @notice Yield stays off: no call by anyone but the timelock (which can upgrade) turns it on.
    function check_yieldOff_staysOff(address caller) public {
        vm.assume(caller != timelock);
        assert(lock.yieldDisabled());

        _arbitraryCall(address(lock), "PendleYTLock", caller);

        assert(lock.yieldDisabled());
    }

    /// @notice Every yield entry point reverts for every caller, the admin included.
    function check_yieldOff_yieldCallsRevert(address caller, uint8 which, address to) public {
        vm.assume(which < 5);
        bytes memory data = which == 0
            ? abi.encodeCall(lock.claimYield, ())
            : which == 1
                ? abi.encodeCall(lock.claimYieldTo, (to))
                : which == 2
                    ? abi.encodeCall(lock.claimPendleYield, ())
                    : which == 3
                        ? abi.encodeCall(lock.rescueOrphanYield, (to))
                        : abi.encodeCall(lock.initializeYieldDistribution, ());
        vm.prank(caller);
        (bool ok,) = address(lock).call(data);
        assert(!ok);
    }

    /// @notice The locked YT always covers totalAssets, whatever anyone but the timelock does.
    function check_yieldOff_principalAlwaysBacked(address caller, uint8 k) public {
        vm.assume(caller != timelock);
        _deposits(k);
        vm.prank(admin);
        lock.unpauseWithdrawals();

        _arbitraryCall(address(lock), "PendleYTLock", caller);

        assert(yt.balanceOf(address(lock)) >= lock.totalAssets());
    }

    /// @notice While withdrawals are paused nobody can withdraw or redeem, in this mode too.
    function check_yieldOff_withdrawalsPausedBlockExit(address caller, uint256 amount, bool useRedeem) public {
        _deposits(0);
        vm.prank(caller);
        (bool ok,) = address(lock).call(
            useRedeem
                ? abi.encodeCall(lock.redeem, (amount, caller, caller))
                : abi.encodeCall(lock.withdraw, (amount, caller, caller))
        );
        assert(!ok);
    }
}
