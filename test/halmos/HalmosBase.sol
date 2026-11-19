// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

/// @notice The subset of the halmos symbolic cheatcodes (halmos-cheatcodes) these properties use.
/// @dev Declared here rather than pulled in as a dependency so `forge build` needs nothing beyond
///      forge-std. The address and selectors are fixed by halmos.
interface SVM {
    function createUint(uint256 bitSize, string memory name) external pure returns (uint256);
    function createUint256(string memory name) external pure returns (uint256);
    function createAddress(string memory name) external pure returns (address);
    function createBool(string memory name) external pure returns (bool);
    function createBytes(uint256 byteSize, string memory name) external pure returns (bytes memory);
    function createBytes32(string memory name) external pure returns (bytes32);
    function createCalldata(string memory contractName) external pure returns (bytes memory);
    function createCalldata(string memory contractName, bool includeViewFunctions) external pure returns (bytes memory);
    function enableSymbolicStorage(address target) external;
}

/// @title HalmosBase
/// @notice Shared helpers for the `check_*` properties under test/halmos.
/// @dev halmos treats a reverting path as "no counterexample". A property that must hold whatever the
///      caller does is therefore written as: run an arbitrary call, then assert on the state it leaves.
///      A property that something must revert is written with a low-level call and `assert(!ok)`.
abstract contract HalmosBase is Test {
    SVM internal constant svm = SVM(address(uint160(uint256(keccak256("svm cheat code")))));

    /// @dev Calls `target` with symbolic calldata covering every non-view function of `contractName`
    ///      (one path per function, plus the empty and fallback calldata), from `caller`.
    ///      The zero address is excluded as a caller: no transaction can originate from it, and admitting
    ///      it produces spurious counterexamples (e.g. Ownable2Step's acceptOwnership while no transfer is
    ///      pending, since pendingOwner() == address(0) == msg.sender).
    function _arbitraryCall(address target, string memory contractName, address caller) internal returns (bool ok) {
        vm.assume(caller != address(0));
        bytes memory data = svm.createCalldata(contractName);
        vm.prank(caller);
        (ok,) = target.call(data);
    }

    /// @dev bool to 0/1 without a conditional jump. halmos counts every revisit of a symbolic branch as a
    ///      loop iteration, so properties fold per-item checks into bitmasks with this and assert once.
    function _bit(bool b) internal pure returns (uint256 v) {
        assembly {
            v := b
        }
    }

    /// @dev Selector of a symbolic calldata blob, or zero for calldata shorter than four bytes.
    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }
}
