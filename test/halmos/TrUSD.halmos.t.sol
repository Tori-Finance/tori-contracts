// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TrUSD } from "../../contracts/core/TrUSD.sol";
import { HalmosBase } from "./HalmosBase.sol";

/// @title TrUSDHalmos
/// @notice Symbolic properties of the trUSD token, run through its ERC1967 proxy as deployed.
contract TrUSDHalmos is HalmosBase {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    TrUSD internal trUSD;
    address internal admin = address(0xA11CE);
    address internal timelock = address(0x71E10C);
    address internal minter = address(0x111111);

    function setUp() public {
        TrUSD impl = new TrUSD();
        trUSD = TrUSD(address(new ERC1967Proxy(address(impl), abi.encodeCall(TrUSD.initialize, (admin)))));
        vm.prank(admin);
        trUSD.initializeTimelockAdmin(timelock);
        vm.prank(timelock);
        trUSD.setMinter(minter);
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(trUSD), IMPLEMENTATION_SLOT))));
    }

    /// @notice Only the configured minter can mint, for any recipient and amount.
    function check_mint_onlyMinter(address caller, address to, uint256 amount) public {
        vm.assume(caller != minter);
        vm.prank(caller);
        (bool ok,) = address(trUSD).call(abi.encodeCall(TrUSD.mint, (to, amount)));
        assert(!ok);
    }

    /// @notice No call by anyone but the minter can increase total supply.
    /// @dev The timelock is excluded: its upgrade right can by design replace the logic.
    function check_totalSupply_onlyMinterIncreases(address caller, uint256 seed) public {
        vm.assume(caller != timelock);
        vm.prank(minter);
        trUSD.mint(address(0xB0B), seed);

        uint256 supplyBefore = trUSD.totalSupply();
        _arbitraryCall(address(trUSD), "TrUSD", caller);
        uint256 supplyAfter = trUSD.totalSupply();

        if (supplyAfter > supplyBefore) assert(caller == minter);
    }

    /// @notice A holder's balance can only go down by the holder's own call or an allowance-holder's call.
    /// @dev The timelock is excluded: its upgrade right can by design replace the logic. Permit is
    ///      included; within one call it can set an allowance but cannot also spend it.
    function check_balance_onlyOwnerOrSpenderDecreases(address caller, uint256 amount) public {
        address victim = address(0xB0B);
        vm.assume(caller != victim && caller != timelock);
        vm.prank(minter);
        trUSD.mint(victim, amount);
        vm.assume(trUSD.allowance(victim, caller) == 0);

        uint256 balBefore = trUSD.balanceOf(victim);
        _arbitraryCall(address(trUSD), "TrUSD", caller);
        assert(trUSD.balanceOf(victim) >= balBefore);
    }

    /// @notice transfer moves exactly `amount` from sender to recipient and leaves supply unchanged.
    function check_transfer_conservesSupply(address from, address to, uint256 minted, uint256 amount) public {
        vm.assume(from != address(0) && to != address(0) && from != to);
        vm.prank(minter);
        trUSD.mint(from, minted);

        uint256 supply = trUSD.totalSupply();
        uint256 fromBefore = trUSD.balanceOf(from);
        uint256 toBefore = trUSD.balanceOf(to);

        vm.prank(from);
        (bool ok,) = address(trUSD).call(abi.encodeCall(trUSD.transfer, (to, amount)));

        if (ok) {
            assert(trUSD.balanceOf(from) == fromBefore - amount);
            assert(trUSD.balanceOf(to) == toBefore + amount);
        } else {
            assert(amount > fromBefore);
        }
        assert(trUSD.totalSupply() == supply);
    }

    /// @notice burn and burnFrom reduce supply by exactly the burnt amount.
    function check_burn_reducesSupplyExactly(uint256 minted, uint256 amount) public {
        address holder = address(0xB0B);
        vm.prank(minter);
        trUSD.mint(holder, minted);
        uint256 supply = trUSD.totalSupply();

        vm.prank(holder);
        trUSD.burn(amount);

        assert(trUSD.totalSupply() == supply - amount);
        assert(trUSD.balanceOf(holder) == minted - amount);
    }

    /// @notice Nobody but the timelock can change the implementation, by any call.
    function check_upgrade_onlyTimelock(address caller) public {
        vm.assume(caller != timelock);
        address implBefore = _implementation();
        _arbitraryCall(address(trUSD), "TrUSD", caller);
        assert(_implementation() == implBefore);
    }

    /// @notice Upgrading to a genuine new implementation reverts for every caller but the timelock.
    /// @dev Complements check_upgrade_onlyTimelock with a concrete UUPS-compatible target, so a broken
    ///      guard shows up as a counterexample rather than as an aborted path.
    function check_upgradeToAndCall_onlyTimelock(address caller) public {
        vm.assume(caller != timelock);
        TrUSD next = new TrUSD();
        vm.prank(caller);
        (bool ok,) = address(trUSD).call(abi.encodeCall(trUSD.upgradeToAndCall, (address(next), "")));
        assert(!ok);
    }

    /// @notice Minter, timelock role and admin role can only be changed by the admin or the timelock.
    function check_privilegedState_onlyAdminOrTimelock(address caller, address who) public {
        vm.assume(caller != admin && caller != timelock);
        bytes32 timelockRole = trUSD.TIMELOCK_ADMIN_ROLE();
        bytes32 adminRole = trUSD.DEFAULT_ADMIN_ROLE();

        address minterBefore = trUSD.minter();
        bool tlBefore = trUSD.hasRole(timelockRole, who);
        bool adBefore = trUSD.hasRole(adminRole, who);

        _arbitraryCall(address(trUSD), "TrUSD", caller);

        assert(trUSD.minter() == minterBefore);
        assert(trUSD.hasRole(timelockRole, who) == tlBefore);
        assert(trUSD.hasRole(adminRole, who) == adBefore);
    }

    /// @notice Once bootstrapped, even the admin cannot grant, revoke or re-seat TIMELOCK_ADMIN_ROLE,
    ///         nor change the minter.
    function check_admin_cannotTouchTimelockRoleOrMinter(address who) public {
        bytes32 timelockRole = trUSD.TIMELOCK_ADMIN_ROLE();
        bool before = trUSD.hasRole(timelockRole, who);
        address minterBefore = trUSD.minter();

        _arbitraryCall(address(trUSD), "TrUSD", admin);

        assert(trUSD.hasRole(timelockRole, who) == before);
        assert(trUSD.minter() == minterBefore);
    }

    /// @notice renounceRole always reverts, so no role holder can leave the contract ungoverned.
    function check_renounceRole_alwaysReverts(address caller, bytes32 role, address account) public {
        vm.prank(caller);
        (bool ok,) = address(trUSD).call(abi.encodeCall(trUSD.renounceRole, (role, account)));
        assert(!ok);
    }

    /// @notice Neither the proxy nor the bare implementation can be initialized a second time.
    function check_initialize_notReplayable(address caller, address newAdmin) public {
        vm.prank(caller);
        (bool ok,) = address(trUSD).call(abi.encodeCall(TrUSD.initialize, (newAdmin)));
        assert(!ok);

        vm.prank(caller);
        (ok,) = _implementation().call(abi.encodeCall(TrUSD.initialize, (newAdmin)));
        assert(!ok);
    }
}
