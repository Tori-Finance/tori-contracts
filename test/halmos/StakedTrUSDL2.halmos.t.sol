// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { StakedTrUSDL2 } from "../../contracts/omnichain/StakedTrUSDL2.sol";
import { HalmosBase } from "./HalmosBase.sol";

/// @title StakedTrUSDL2Halmos
/// @notice The CCIP destination-chain strUSD: mint authority, max supply and the blacklist.
/// @dev Kept in its own file: the token builds on OpenZeppelin 4.8.3 (vendored with CCIP) and must
///      not share a compilation scope with OpenZeppelin 5 imports.
contract StakedTrUSDL2Halmos is HalmosBase {
    StakedTrUSDL2 internal token;
    address internal owner = address(0x0A0A);
    address internal pool = address(0x9001);
    address internal blackLister = address(0xB1AC);
    address internal blacklisted = address(0xBAD);
    address internal holder = address(0x401D);
    uint256 internal constant MAX_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.prank(owner);
        token = new StakedTrUSDL2("Staked trUSD", "strUSD", 18, MAX_SUPPLY, 0, owner);
        vm.startPrank(owner);
        token.grantMintAndBurnRoles(pool);
        token.setBlackLister(blackLister);
        vm.stopPrank();

        vm.startPrank(pool);
        token.mint(holder, 100e18);
        token.mint(blacklisted, 50e18);
        vm.stopPrank();
        vm.prank(blackLister);
        token.addToBlackList(blacklisted);
    }

    /// @notice Only a granted minter can increase supply, by any call.
    function check_supply_onlyMinterIncreases(address caller) public {
        uint256 supply = token.totalSupply();
        _arbitraryCall(address(token), "StakedTrUSDL2", caller);
        if (token.totalSupply() > supply) assert(caller == pool);
    }

    /// @notice No sequence of two mints can take supply above maxSupply.
    function check_mint_neverAboveMaxSupply(uint256 a, uint256 b, address to) public {
        vm.prank(pool);
        (bool ok,) = address(token).call(abi.encodeCall(token.mint, (to, a)));
        vm.prank(pool);
        (ok,) = address(token).call(abi.encodeCall(token.mint, (to, b)));
        assert(token.totalSupply() <= MAX_SUPPLY);
    }

    /// @notice A blacklisted balance cannot move by any call from anyone but the owner, the CCIP pool
    ///         (minter and burner) and the blacklister included. (The blacklister can lift the entry,
    ///         which is its role; who can change entries is check_blacklist_onlyBlackLister.)
    function check_blacklisted_frozen(address caller) public {
        vm.assume(caller != owner);
        uint256 bal = token.balanceOf(blacklisted);
        _arbitraryCall(address(token), "StakedTrUSDL2", caller);
        assert(token.balanceOf(blacklisted) == bal);
    }

    /// @notice Blacklist entries change only by the blacklister; the owner's redistribution restores
    ///         the entry within the same call.
    function check_blacklist_onlyBlackLister(address caller, address who) public {
        vm.assume(caller != blackLister);
        bool before = token.blackList(who);
        _arbitraryCall(address(token), "StakedTrUSDL2", caller);
        assert(token.blackList(who) == before);
    }

    /// @notice A bridge-in (pool mint) to a blacklisted address always reverts, so the inbound CCIP
    ///         message fails atomically.
    function check_mintToBlacklisted_reverts(uint256 amount) public {
        vm.prank(pool);
        (bool ok,) = address(token).call(abi.encodeCall(token.mint, (blacklisted, amount)));
        assert(!ok);
    }

    /// @notice Only the owner can change the blacklister, the minters/burners or the CCIP admin.
    function check_config_onlyOwner(address caller, address who) public {
        vm.assume(caller != owner);
        address bl = token.blackLister();
        address ccipAdmin = token.getCCIPAdmin();
        bool m = token.isMinter(who);
        bool b = token.isBurner(who);
        _arbitraryCall(address(token), "StakedTrUSDL2", caller);
        assert(token.blackLister() == bl);
        assert(token.getCCIPAdmin() == ccipAdmin);
        assert(token.isMinter(who) == m);
        assert(token.isBurner(who) == b);
    }
}
