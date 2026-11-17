// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TrUsdSilo } from "../../contracts/core/TrUsdSilo.sol";
import { StakingRewardsDistributor } from "../../contracts/core/StakingRewardsDistributor.sol";
import { IStakedTrUSD } from "../../contracts/interfaces/IStakedTrUSD.sol";
import { StakedTrUSDFixture } from "./StakedTrUSD.halmos.t.sol";
import { HalmosToken } from "./HalmosMocks.sol";

/// @title TrUsdSiloHalmos
/// @notice The cooldown silo: only the vault moves its trUSD, and it always covers every cooldown.
contract TrUsdSiloHalmos is StakedTrUSDFixture {
    TrUsdSilo internal silo;
    HalmosToken internal other;

    function setUp() public {
        _deploy();
        silo = TrUsdSilo(vault.silo());
        other = new HalmosToken("OTHER", 18);
        _stake(alice, 10 ether);
        _stake(bob, 10 ether);
        vm.prank(alice);
        vault.cooldownShares(2 ether);
        vm.prank(bob);
        vault.cooldownShares(3 ether);
        other.mint(address(silo), 1 ether);
    }

    /// @notice Nobody but the vault can move any token out of the silo, by any call.
    function check_silo_onlyVaultMovesFunds(address caller) public {
        vm.assume(caller != address(vault));
        uint256 t = trUSD.balanceOf(address(silo));
        uint256 o = other.balanceOf(address(silo));
        _arbitraryCall(address(silo), "TrUsdSilo", caller);
        assert(trUSD.balanceOf(address(silo)) == t);
        assert(other.balanceOf(address(silo)) == o);
    }

    /// @notice Even the vault cannot pull trUSD out through the rescue path.
    function check_silo_rescueCannotTakeTrUSD(address to, uint256 amount) public {
        vm.prank(address(vault));
        (bool ok,) = address(silo).call(abi.encodeCall(silo.rescueToken, (IERC20(address(trUSD)), to, amount)));
        assert(!ok);
    }

    /// @notice The silo's trUSD covers every open cooldown after any vault call by anyone but the
    ///         timelock, the admin's seize and rescue powers included.
    function check_silo_coversAllCooldowns(address caller, uint256 warp) public {
        vm.assume(caller != timelock);
        vm.assume(warp < 365 days);
        vm.warp(block.timestamp + warp);

        _arbitraryCall(address(vault), "StakedTrUSD", caller);

        uint256 owed = vault.cooldowns(alice).underlyingAmount + vault.cooldowns(bob).underlyingAmount;
        if (caller != alice && caller != bob) owed += vault.cooldowns(caller).underlyingAmount;
        assert(trUSD.balanceOf(address(silo)) >= owed);
    }
}

/// @title StakingRewardsDistributorHalmos
/// @notice The rewards distributor: only the operator moves rewards, only the owner configures, and
///         the reward token can never be rescued out.
contract StakingRewardsDistributorHalmos is StakedTrUSDFixture {
    StakingRewardsDistributor internal distributor;
    address internal owner = address(0x0A0A);
    address internal operator = address(0x0909);

    function setUp() public {
        _deploy();
        distributor =
            new StakingRewardsDistributor(IStakedTrUSD(address(vault)), IERC20(address(trUSD)), owner, operator);
        vm.prank(admin);
        vault.grantRole(REWARDER_ROLE, address(distributor));
        _stake(alice, 10 ether);
        trUSD.mint(address(distributor), 1000 ether);
    }

    /// @notice No call by anyone but the operator can take trUSD out of the distributor or change the
    ///         vault's vesting state through it.
    function check_onlyOperatorMovesRewards(address caller) public {
        vm.assume(caller != operator);
        uint256 bal = trUSD.balanceOf(address(distributor));
        uint256 vesting = vault.vestingAmount();
        _arbitraryCall(address(distributor), "StakingRewardsDistributor", caller);
        assert(trUSD.balanceOf(address(distributor)) >= bal);
        assert(vault.vestingAmount() == vesting);
    }

    /// @notice Nobody but the owner can change the operator, the owner, or the vault allowance.
    function check_config_onlyOwner(address caller) public {
        vm.assume(caller != owner);
        address op = distributor.operator();
        address own = distributor.owner();
        address pending = distributor.pendingOwner();
        uint256 allowance = trUSD.allowance(address(distributor), address(vault));

        _arbitraryCall(address(distributor), "StakingRewardsDistributor", caller);

        assert(distributor.operator() == op);
        assert(distributor.owner() == own);
        assert(distributor.pendingOwner() == pending);
        assert(trUSD.allowance(address(distributor), address(vault)) == allowance);
    }

    /// @notice The owner can never rescue the reward token, and can never renounce ownership.
    function check_owner_cannotRescueTrUSDOrRenounce(address to, uint256 amount) public {
        vm.prank(owner);
        (bool ok,) = address(distributor).call(abi.encodeCall(distributor.rescueTokens, (address(trUSD), to, amount)));
        assert(!ok);
        vm.prank(owner);
        (ok,) = address(distributor).call(abi.encodeCall(distributor.renounceOwnership, ()));
        assert(!ok);
    }

    /// @notice A reward moves exactly the requested amount into the vault and vests all of it.
    function check_transferInRewards_exact(uint256 amount) public {
        uint256 d = trUSD.balanceOf(address(distributor));
        uint256 v = trUSD.balanceOf(address(vault));
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(operator);
        distributor.transferInRewards(amount);

        assert(trUSD.balanceOf(address(distributor)) == d - amount);
        assert(trUSD.balanceOf(address(vault)) == v + amount);
        assert(vault.vestingAmount() == amount);
        assert(vault.totalAssets() == assetsBefore);
    }
}
